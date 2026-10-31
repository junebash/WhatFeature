import Foundation
import HummingbirdTesting
import Testing
import WhatFeatureAPI
import WhatFeatureClient
import WhatFeatureCore
import WhatFeatureServer
import WhatFeatureStorage

/// Runs a real server on a free port and hands the test a client for it.
private func withLiveServer(_ test: @Sendable (AdminClient, SQLiteStore) async throws -> Void) async throws {
    let store = try SQLiteStore.inMemory()
    let admin = try await store.createAdminToken(name: "test", by: .system("test"))
    try await buildApplication(store: store).test(.live) { client in
        let port = try #require(client.port)
        let baseURL = try #require(URL(string: "http://127.0.0.1:\(port)"))
        try await test(AdminClient(baseURL: baseURL, token: admin.secret), store)
    }
}

@Suite struct AdminClientTests {
    @Test func coversTheWholeLifecycle() async throws {
        try await withLiveServer { client, _ in
            #expect(try await client.me().kind == .admin)

            _ = try await client.createProject(key: "demo", name: "Demo")
            _ = try await client.createEnvironment(project: "demo", key: "dev")
            #expect(try await client.projects().map(\.key) == ["demo"])
            #expect(try await client.environments(project: "demo").map(\.key) == ["dev"])

            let created = try await client.createFlag(
                project: "demo",
                CreateFlagRequest(key: "beta", type: .boolean, variants: ["on": true, "off": false], description: "Beta")
            )
            #expect(created.configs["dev"]?.enabled == false)

            var config = try await client.config(project: "demo", environment: "dev", flag: "beta")
            config.enabled = true
            config.defaultResult = .variant("on")
            let saved = try await client.setConfig(config, project: "demo", environment: "dev", flag: "beta")
            #expect(saved.version == 2)

            let result = try await client.evaluate(project: "demo", environment: "dev", flag: "beta", context: EvaluationContext())
            #expect(result.value == true)
            #expect(result.reason == .static)

            _ = try await client.updateFlag(project: "demo", key: "beta", changes: .init(description: "Beta features"))
            #expect(try await client.flag(project: "demo", key: "beta").flag.description == "Beta features")

            _ = try await client.setArchived(true, project: "demo", key: "beta")
            #expect(try await client.flags(project: "demo").isEmpty)
            #expect(try await client.flags(project: "demo", includeArchived: true).count == 1)

            try await client.deleteFlag(project: "demo", key: "beta")
            #expect(try await client.flags(project: "demo", includeArchived: true).isEmpty)

            let actions = try await client.audit(project: "demo").map(\.action)
            #expect(actions.first == "flag.delete")
            #expect(actions.contains("flagConfig.update"))
        }
    }

    @Test func tokens() async throws {
        try await withLiveServer { client, store in
            _ = try await client.createProject(key: "demo")
            let dev = try await client.createEnvironment(project: "demo", key: "dev")
            let created = try await client.createToken(CreateTokenRequest(name: "iOS", kind: .evaluation, project: "demo", environment: "dev"))
            #expect(try await store.environment(forTokenHash: TokenHash.of(created.secret)) == dev.id)

            _ = try await client.revokeToken(created.token.id)
            #expect(try await store.environment(forTokenHash: TokenHash.of(created.secret)) == nil)
            #expect(try await client.tokens().count == 2)
        }
    }

    @Test func serverErrorsKeepTheirMessageAndIssues() async throws {
        try await withLiveServer { client, _ in
            _ = try await client.createProject(key: "demo")
            let conflict = await #expect(throws: AdminClientError.self) { try await client.createProject(key: "demo") }
            #expect(conflict?.status == 409)
            #expect(conflict?.description == "A project with key 'demo' already exists (HTTP 409)")

            let invalid = await #expect(throws: AdminClientError.self) {
                try await client.createFlag(project: "demo", CreateFlagRequest(key: "bad", type: .boolean, variants: ["on": "yes"]))
            }
            #expect(invalid?.description == "Invalid (HTTP 400)\n  - Variant 'on' doesn't match the flag type 'boolean'")

            let missing = await #expect(throws: AdminClientError.self) { try await client.project("nope") }
            #expect(missing?.status == 404)
        }
    }

    /// Every query parameter, sent through the client, so a renamed parameter fails here.
    @Test func flagListQuery() async throws {
        try await withLiveServer { client, _ in
            let me = try await client.me()
            _ = try await client.createProject(key: "demo")
            _ = try await client.createFlag(project: "demo", CreateFlagRequest(key: "b-second", type: .boolean, variants: ["on": true]))
            _ = try await client.createFlag(project: "demo", CreateFlagRequest(key: "a-third", type: .boolean, variants: ["on": true]))
            _ = try await client.createFlag(project: "demo", CreateFlagRequest(key: "c-archived", type: .boolean, variants: ["on": true]))
            _ = try await client.setArchived(true, project: "demo", key: "c-archived")

            #expect(try await client.flags(project: "demo").map(\.key) == ["a-third", "b-second"])
            #expect(try await client.flags(project: "demo", descending: true).map(\.key) == ["b-second", "a-third"])
            #expect(try await client.flags(project: "demo", sort: .createdAt).map(\.key) == ["b-second", "a-third"])
            #expect(try await client.flags(project: "demo", includeArchived: true).map(\.key) == ["a-third", "b-second", "c-archived"])
            #expect(try await client.flags(project: "demo", createdBy: "token:\(me.id)").count == 2)
            #expect(try await client.flags(project: "demo", createdBy: "token:nobody").isEmpty)
        }
    }

    @Test func auditQuery() async throws {
        try await withLiveServer { client, store in
            let me = try await client.me()
            _ = try await client.createProject(key: "demo")
            _ = try await client.createProject(key: "other")
            _ = try await client.createFlag(project: "demo", CreateFlagRequest(key: "beta", type: .boolean, variants: ["on": true]))
            _ = try await store.createProject(key: "by-system", name: "x", by: .system("test"))

            #expect(try await client.audit(project: "demo").map(\.action) == ["flag.create", "project.create"])
            #expect(try await client.audit(flag: "beta").map(\.action) == ["flag.create"])
            #expect(try await client.audit(actor: "system:test").map(\.action) == ["project.create", "token.create"])
            #expect(try await client.audit(actor: "token:\(me.id)").count == 3)
            #expect(try await client.audit(limit: 2).count == 2)
            #expect(try await client.audit(since: Date().addingTimeInterval(3_600)).isEmpty)
            #expect(try await client.audit(until: Date().addingTimeInterval(-3_600)).isEmpty)
        }
    }

    @Test func badTokenIs401() async throws {
        try await withLiveServer { client, _ in
            var wrong = client
            wrong.token = "wf_admin_nope"
            let error = await #expect(throws: AdminClientError.self) { try await wrong.me() }
            #expect(error?.status == 401)
        }
    }
}
