import Foundation
import Synchronization
import Testing
import WhatFeatureCore
import WhatFeatureStorage

private let me = AuditActor.system("test")

/// A project with `dev` and `prod`, and one boolean flag.
private func makeStore() async throws -> (SQLiteStore, Project, dev: Environment, prod: Environment) {
    let store = try SQLiteStore.inMemory()
    let project = try await store.createProject(key: "demo", name: "Demo", by: me)
    let dev = try await store.createEnvironment(key: "dev", name: "Dev", in: project.id, by: me)
    let prod = try await store.createEnvironment(key: "prod", name: "Prod", in: project.id, by: me)
    try await store.createFlag(key: "beta", type: .boolean, variants: ["on": true, "off": false], in: project.id, by: me)
    return (store, project, dev, prod)
}

@Suite struct ProjectAndEnvironmentTests {
    @Test func rejectsDuplicateKeys() async throws {
        let (store, project, _, _) = try await makeStore()
        await #expect(throws: StoreError.conflict("A project with key 'demo' already exists")) {
            try await store.createProject(key: "demo", name: "Again", by: me)
        }
        await #expect(throws: StoreError.conflict("An environment with key 'dev' already exists in this project")) {
            try await store.createEnvironment(key: "dev", name: "Again", in: project.id, by: me)
        }
        await #expect(throws: StoreError.conflict("A flag with key 'beta' already exists in this project")) {
            try await store.createFlag(key: "beta", type: .boolean, variants: ["on": true], in: project.id, by: me)
        }
    }

    @Test func rejectsBadKeys() async throws {
        let store = try SQLiteStore.inMemory()
        await #expect(throws: StoreError.self) {
            try await store.createProject(key: "has space", name: "x", by: me)
        }
    }

    @Test func newEnvironmentGetsDisabledConfigsForExistingFlags() async throws {
        let (store, project, _, _) = try await makeStore()
        let staging = try await store.createEnvironment(key: "staging", name: "Staging", in: project.id, by: me)
        let config = try #require(try await store.config(flagKey: "beta", in: staging.id))
        #expect(config == FlagConfig(enabled: false, defaultResult: .variant("off"), version: 1))
    }
}

@Suite struct FlagTests {
    @Test func newFlagIsDisabledInEveryEnvironment() async throws {
        let (store, _, dev, prod) = try await makeStore()
        for environment in [dev, prod] {
            #expect(try await store.config(flagKey: "beta", in: environment.id)?.enabled == false)
            let result = try await store.snapshot(for: environment.id).evaluate(flagKey: "beta", context: EvaluationContext())
            #expect(result.outcome == .disabled)
        }
    }

    @Test func defaultVariantCanBeChosen() async throws {
        let (store, project, dev, _) = try await makeStore()
        try await store.createFlag(
            key: "welcome", type: .string, variants: ["short": "Hi", "long": "Welcome back"], defaultVariant: "short",
            in: project.id, by: me
        )
        #expect(try await store.config(flagKey: "welcome", in: dev.id)?.defaultResult == .variant("short"))

        await #expect(throws: StoreError.invalid(["Default variant 'medium' isn't one of the flag's variants"])) {
            try await store.createFlag(key: "other", type: .string, variants: ["a": "A"], defaultVariant: "medium", in: project.id, by: me)
        }
    }

    @Test func rejectsInvalidFlag() async throws {
        let (store, project, _, _) = try await makeStore()
        await #expect(throws: StoreError.invalid(["Variant 'on' doesn't match the flag type 'boolean'"])) {
            try await store.createFlag(key: "bad", type: .boolean, variants: ["on": "yes"], in: project.id, by: me)
        }
    }

    @Test func roundTripsEveryField() async throws {
        let (store, project, _, _) = try await makeStore()
        let created = try await store.createFlag(
            key: "theme", type: .object, variants: ["dark": ["background": "#000", "contrast": 1.5]],
            description: "Colors", isExperiment: true, in: project.id, by: me
        )
        let fetched = try await store.flag(key: "theme", in: project.id)
        #expect(fetched?.variants == created.variants)
        #expect(fetched?.isExperiment == true)
        #expect(fetched?.createdBy == "system:test")
        // SQLite keeps dates to the millisecond.
        #expect(abs((fetched?.createdAt.timeIntervalSince1970 ?? 0) - created.createdAt.timeIntervalSince1970) < 0.001)
    }

    @Test func setConfigValidatesAndBumpsVersions() async throws {
        let (store, _, dev, prod) = try await makeStore()
        let devVersion = try await store.snapshot(for: dev.id).version
        let prodVersion = try await store.snapshot(for: prod.id).version

        let saved = try await store.setConfig(
            FlagConfig(enabled: true, defaultResult: .variant("on"), version: 999),
            flagKey: "beta", in: dev.id, by: me
        )
        #expect(saved.version == 2, "The store decides the version, not the caller")

        let snapshot = try await store.snapshot(for: dev.id)
        #expect(snapshot.version > devVersion)
        #expect(snapshot.evaluate(flagKey: "beta", context: EvaluationContext()).reason == .static)
        #expect(try await store.snapshot(for: prod.id).version == prodVersion, "Other environments are untouched")

        await #expect(throws: StoreError.invalid(["Default: unknown variant 'maybe'"])) {
            try await store.setConfig(FlagConfig(enabled: true, defaultResult: .variant("maybe")), flagKey: "beta", in: dev.id, by: me)
        }
    }

    @Test func archivingHidesTheFlag() async throws {
        let (store, project, dev, _) = try await makeStore()
        try await store.setConfig(FlagConfig(enabled: true, defaultResult: .variant("on")), flagKey: "beta", in: dev.id, by: me)
        try await store.setArchived(true, flagKey: "beta", in: project.id, by: me)

        #expect(try await store.flags(in: project.id).isEmpty)
        #expect(try await store.flags(in: project.id, includeArchived: true).map(\.key) == ["beta"])
        let snapshot = try await store.snapshot(for: dev.id)
        #expect(snapshot.evaluateAll(context: EvaluationContext()).isEmpty)
        #expect(snapshot.evaluate(flagKey: "beta", context: EvaluationContext()).outcome == .disabled)

        try await store.setArchived(false, flagKey: "beta", in: project.id, by: me)
        #expect(try await store.snapshot(for: dev.id).evaluate(flagKey: "beta", context: EvaluationContext()).reason == .static)
    }
}

@Suite struct AuditTests {
    @Test func everyWriteIsRecorded() async throws {
        let (store, project, dev, _) = try await makeStore()
        try await store.setConfig(FlagConfig(enabled: true, defaultResult: .variant("on")), flagKey: "beta", in: dev.id, by: me)
        try await store.setArchived(true, flagKey: "beta", in: project.id, by: me)
        try await store.setArchived(true, flagKey: "beta", in: project.id, by: me)  // no change, so not recorded

        let actions = try await store.auditEntries().map(\.action)
        #expect(actions == ["flag.archive", "flagConfig.update", "flag.create", "environment.create", "environment.create", "project.create"])
    }

    @Test func configChangeRecordsBeforeAndAfter() async throws {
        let (store, _, dev, _) = try await makeStore()
        try await store.setConfig(FlagConfig(enabled: true, defaultResult: .variant("on")), flagKey: "beta", in: dev.id, by: me)

        let entry = try #require(try await store.auditEntries(flagKey: "beta").first)
        #expect(entry.action == "flagConfig.update")
        #expect(entry.actor == "system:test")
        #expect(entry.environmentID == dev.id)
        let before = try JSONDecoder().decode(FlagConfig.self, from: Data(try #require(entry.before).utf8))
        let after = try JSONDecoder().decode(FlagConfig.self, from: Data(try #require(entry.after).utf8))
        #expect(before.enabled == false)
        #expect(after.enabled == true)
    }
}

@Suite struct TokenTests {
    @Test func evaluationTokenFindsItsEnvironment() async throws {
        let (store, _, dev, _) = try await makeStore()
        let created = try await store.createEvaluationToken(name: "iOS", for: dev.id, by: me)
        #expect(created.secret.hasPrefix("wf_eval_"))
        #expect(created.secret.count == "wf_eval_".count + 43)
        #expect(try await store.environment(forTokenHash: TokenHash.of(created.secret)) == dev.id)
    }

    @Test func adminTokenCantEvaluate() async throws {
        let (store, _, _, _) = try await makeStore()
        let created = try await store.createAdminToken(name: "laptop", by: me)
        #expect(created.secret.hasPrefix("wf_admin_"))
        #expect(try await store.authenticate(tokenHash: TokenHash.of(created.secret))?.kind == .admin)
        #expect(try await store.environment(forTokenHash: TokenHash.of(created.secret)) == nil)
    }

    @Test func revokedTokensStopWorking() async throws {
        let (store, _, dev, _) = try await makeStore()
        let created = try await store.createEvaluationToken(name: "iOS", for: dev.id, by: me)
        try await store.revokeToken(created.token.id, by: me)
        #expect(try await store.environment(forTokenHash: TokenHash.of(created.secret)) == nil)
        #expect(try await store.tokens().first?.isRevoked == true)
    }

    @Test func evaluationTokenChangesShowUpInTheProjectAuditLog() async throws {
        let (store, project, dev, _) = try await makeStore()
        let created = try await store.createEvaluationToken(name: "iOS", for: dev.id, by: me)
        try await store.revokeToken(created.token.id, by: me)
        let actions = try await store.auditEntries(projectID: project.id, limit: 2).map(\.action)
        #expect(actions == ["token.revoke", "token.create"])
    }

    @Test func secretsNeverReachTheDatabaseOrAuditLog() async throws {
        let (store, _, dev, _) = try await makeStore()
        let created = try await store.createEvaluationToken(name: "iOS", for: dev.id, by: me)
        let entry = try #require(try await store.auditEntries().first)
        #expect(entry.action == "token.create")
        #expect(entry.after?.contains(created.secret) == false)
        #expect(entry.after?.contains(TokenHash.of(created.secret)) == false)
    }

    @Test func lastUsedIsRecordedAtMostOncePerMinute() async throws {
        let clock = TestClock()
        let store = try SQLiteStore.inMemory(now: clock.now)
        let created = try await store.createAdminToken(name: "laptop", by: me)
        let hash = TokenHash.of(created.secret)

        _ = try await store.authenticate(tokenHash: hash)
        let first = try #require(try await store.tokens().first?.lastUsedAt)

        clock.advance(by: 30)
        _ = try await store.authenticate(tokenHash: hash)
        #expect(try await store.tokens().first?.lastUsedAt == first)

        clock.advance(by: 31)
        _ = try await store.authenticate(tokenHash: hash)
        #expect(try await store.tokens().first?.lastUsedAt != first)
    }
}

@Suite struct PersistenceTests {
    @Test func survivesReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "whatfeature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "test.sqlite").path

        let secret: String
        let environmentID: EnvironmentID
        do {
            let store = try SQLiteStore(path: path)
            let project = try await store.createProject(key: "demo", name: "Demo", by: me)
            let dev = try await store.createEnvironment(key: "dev", name: "Dev", in: project.id, by: me)
            try await store.createFlag(key: "beta", type: .boolean, variants: ["on": true, "off": false], in: project.id, by: me)
            try await store.setConfig(FlagConfig(enabled: true, defaultResult: .variant("on")), flagKey: "beta", in: dev.id, by: me)
            secret = try await store.createEvaluationToken(name: "iOS", for: dev.id, by: me).secret
            environmentID = dev.id
        }

        let reopened = try SQLiteStore(path: path)
        #expect(try await reopened.environment(forTokenHash: TokenHash.of(secret)) == environmentID)
        let result = try await reopened.snapshot(for: environmentID).evaluate(flagKey: "beta", context: EvaluationContext())
        #expect(result.outcome == .resolved(value: true, variant: "on", reason: .static, matchedRule: nil))
    }
}

@Suite struct SeedTests {
    static let exampleSeed = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "examples/seed.json")

    @Test func exampleSeedLoads() async throws {
        let store = try SQLiteStore.inMemory()
        try await store.load(try Seed.read(from: Self.exampleSeed))

        let project = try #require(try await store.project(key: "demo"))
        #expect(try await store.flags(in: project.id).map(\.key) == ["checkout-v2", "new-onboarding", "welcome-message"])
        let dev = try #require(try await store.environment(key: "dev", in: project.id))
        #expect(try await store.environment(forTokenHash: TokenHash.of("wf_eval_dev_local_only")) == dev.id)
        #expect(try await store.config(flagKey: "new-onboarding", in: dev.id)?.enabled == true)
    }

    @Test func loadingTwiceChangesNothing() async throws {
        let store = try SQLiteStore.inMemory()
        let seed = try Seed.read(from: Self.exampleSeed)
        try await store.load(seed)
        let auditCount = try await store.auditEntries().count
        try await store.load(seed)
        #expect(try await store.auditEntries().count == auditCount)
    }

    @Test func reportsEveryProblem() async throws {
        let json = """
        {"projects": [{"key": "demo", "environments": [{"key": "dev"}], "flags": [
          {"key": "bad", "type": "boolean", "variants": {"on": "yes"}},
          {"key": "ok", "type": "boolean", "variants": {"on": true}, "configs": {
            "dev": {"enabled": true, "defaultResult": {"variant": "maybe"}},
            "nope": {"enabled": true, "defaultResult": {"variant": "on"}}
          }}
        ]}]}
        """
        let store = try SQLiteStore.inMemory()
        let error = try await #require(throws: SeedError.self) {
            try await store.load(try JSONDecoder().decode(Seed.self, from: Data(json.utf8)))
        }
        #expect(error.issues == [
            "demo/bad: Variant 'on' doesn't match the flag type 'boolean'",
            "demo/ok in dev: Default: unknown variant 'maybe'",
            "demo/ok in nope: Unknown environment 'nope'",
        ])
    }
}

@Suite struct IDTests {
    /// IDs come from the `makeID` the store was given, so tests can predict them.
    @Test func newIDsComeFromMakeID() async throws {
        let counter = Mutex(0)
        let store = try SQLiteStore.inMemory(makeID: {
            counter.withLock { count in
                count += 1
                return "id-\(count)"
            }
        })
        let project = try await store.createProject(key: "demo", name: "Demo", by: me)
        let environment = try await store.createEnvironment(key: "dev", name: "Dev", in: project.id, by: me)
        let token = try await store.createAdminToken(name: "laptop", by: me).token
        #expect([project.id.rawValue, environment.id.rawValue, token.id.rawValue] == ["id-1", "id-2", "id-3"])
    }

    @Test func randomIDsAreLowercaseUUIDs() {
        let id = SQLiteStore.randomID()
        #expect(UUID(uuidString: id) != nil)
        #expect(id == id.lowercased())
        #expect(SQLiteStore.randomID() != id)
    }
}

/// A clock tests can move forward by hand.
private final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

    var now: @Sendable () -> Date {
        { self.current.withLock { $0 } }
    }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }
}

