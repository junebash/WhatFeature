public import Foundation
import GRDB
import Synchronization
public import WhatFeatureCore

/// All storage, in one SQLite database.
///
/// Every admin write runs in one transaction together with its audit entry. Evaluation reads come from
/// an in-memory snapshot per environment, refreshed after each write, so they never wait on the database.
/// Only this process should change flags; another process writing to the same file wouldn't refresh the
/// snapshots. (Tokens aren't cached, so the CLI can create or revoke them while the server runs.)
public final class SQLiteStore: EvaluationStore {
    private let database: any DatabaseWriter
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    private let snapshots = Mutex<[EnvironmentID: EnvironmentSnapshot]>([:])
    /// Token ID → the last `lastUsedAt` we wrote, so a busy token doesn't cause a write per request.
    private let tokenLastUsed = Mutex<[String: Date]>([:])

    /// Opens (or creates) a database file and brings its schema up to date.
    ///
    /// - Parameters:
    ///   - now: The clock for timestamps (`createdAt`, `revokedAt`, audit entries, …).
    ///   - makeID: Makes the ID of each new project, environment and token. Random UUIDs by default.
    public convenience init(
        path: String,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = randomID
    ) throws {
        try self.init(database: DatabasePool(path: path), now: now, makeID: makeID)
    }

    /// A database that lives only as long as this object. For tests and quick local runs.
    public static func inMemory(
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = randomID
    ) throws -> SQLiteStore {
        try SQLiteStore(database: DatabaseQueue(), now: now, makeID: makeID)
    }

    /// A random, lowercase UUID: the default for new IDs.
    @Sendable public static func randomID() -> String {
        UUID().uuidString.lowercased()
    }

    private init(database: any DatabaseWriter, now: @escaping @Sendable () -> Date, makeID: @escaping @Sendable () -> String) throws {
        self.database = database
        self.now = now
        self.makeID = makeID
        try Schema.migrator.migrate(database)
    }

    // MARK: - Projects

    public func createProject(key: String, name: String, by actor: AuditActor) async throws -> Project {
        try Self.requireValidKey(key, kind: "Project")
        let project = Project(id: ProjectID(self.makeID()), key: key, name: name, createdAt: now())
        try await database.write { db in
            if try ProjectRecord.filter(Column("key") == key).fetchCount(db) > 0 {
                throw StoreError.conflict("A project with key '\(key)' already exists")
            }
            try ProjectRecord(project).insert(db)
            try self.audit(db, actor, "project.create", project: project.id, after: project)
        }
        return project
    }

    /// Sorted by key.
    public func projects(includeArchived: Bool = false) async throws -> [Project] {
        try await database.read { db in
            var request = ProjectRecord.all()
            if !includeArchived { request = request.filter(Column("archivedAt") == nil) }
            return try request.order(Column("key")).fetchAll(db).map(\.model)
        }
    }

    /// What `updateProject` and `updateEnvironment` can change. `nil` leaves a field as it is. Changing a key
    /// changes admin paths, but not evaluation: tokens point at IDs.
    public struct NameChanges: Sendable, Hashable, Codable {
        public var key: String?
        public var name: String?

        public init(key: String? = nil, name: String? = nil) {
            self.key = key
            self.name = name
        }
    }

    @discardableResult
    public func updateProject(_ projectID: ProjectID, changes: NameChanges, by actor: AuditActor) async throws -> Project {
        if let key = changes.key { try Self.requireValidKey(key, kind: "Project") }
        return try await database.write { db in
            guard var record = try ProjectRecord.fetchOne(db, key: projectID.rawValue) else {
                throw StoreError.notFound("No project with ID '\(projectID)'")
            }
            let before = record.model
            if let key = changes.key, key != record.key {
                if try ProjectRecord.filter(Column("key") == key).fetchCount(db) > 0 {
                    throw StoreError.conflict("A project with key '\(key)' already exists")
                }
                record.key = key
            }
            if let name = changes.name { record.name = name }
            guard record.model != before else { return before }
            try record.update(db)
            try self.audit(db, actor, "project.update", project: projectID, before: before, after: record.model)
            return record.model
        }
    }

    /// Doing nothing (archiving an archived project) isn't recorded.
    @discardableResult
    public func setArchived(_ archived: Bool, project projectID: ProjectID, by actor: AuditActor) async throws -> Project {
        try await database.write { db in
            guard var record = try ProjectRecord.fetchOne(db, key: projectID.rawValue) else {
                throw StoreError.notFound("No project with ID '\(projectID)'")
            }
            guard (record.archivedAt != nil) != archived else { return record.model }
            let before = record.model
            record.archivedAt = archived ? self.now() : nil
            try record.update(db)
            try self.audit(
                db, actor, archived ? "project.archive" : "project.unarchive", project: projectID, before: before, after: record.model
            )
            return record.model
        }
    }

    public func project(key: String) async throws -> Project? {
        try await database.read { db in
            try ProjectRecord.filter(Column("key") == key).fetchOne(db)?.model
        }
    }

    // MARK: - Environments

    /// Every existing flag in the project gets a disabled config in the new environment.
    public func createEnvironment(key: String, name: String, in projectID: ProjectID, by actor: AuditActor) async throws -> Environment {
        try Self.requireValidKey(key, kind: "Environment")
        let environment = Environment(
            id: EnvironmentID(self.makeID()), projectID: projectID, key: key, name: name, version: 1, createdAt: now()
        )
        try await database.write { db in
            try Self.requireProject(projectID, db)
            if try EnvironmentRecord.filter(Column("projectID") == projectID.rawValue && Column("key") == key).fetchCount(db) > 0 {
                throw StoreError.conflict("An environment with key '\(key)' already exists in this project")
            }
            try EnvironmentRecord(environment).insert(db)
            for flag in try FlagRecord.filter(Column("projectID") == projectID.rawValue).fetchAll(db) {
                try Self.insertDefaultConfig(for: flag, in: environment.id, db)
            }
            try self.audit(db, actor, "environment.create", project: projectID, environment: environment.id, after: environment)
        }
        try await refreshSnapshots([environment.id])
        return environment
    }

    /// Sorted by key.
    public func environments(in projectID: ProjectID, includeArchived: Bool = false) async throws -> [Environment] {
        try await database.read { db in
            var request = EnvironmentRecord.filter(Column("projectID") == projectID.rawValue)
            if !includeArchived { request = request.filter(Column("archivedAt") == nil) }
            return try request.order(Column("key")).fetchAll(db).map(\.model)
        }
    }

    @discardableResult
    public func updateEnvironment(_ environmentID: EnvironmentID, changes: NameChanges, by actor: AuditActor) async throws -> Environment {
        if let key = changes.key { try Self.requireValidKey(key, kind: "Environment") }
        return try await database.write { db in
            guard var record = try EnvironmentRecord.fetchOne(db, key: environmentID.rawValue) else {
                throw StoreError.notFound("No environment with ID '\(environmentID)'")
            }
            let before = record.model
            if let key = changes.key, key != record.key {
                if try EnvironmentRecord.filter(Column("projectID") == record.projectID && Column("key") == key).fetchCount(db) > 0 {
                    throw StoreError.conflict("An environment with key '\(key)' already exists in this project")
                }
                record.key = key
            }
            if let name = changes.name { record.name = name }
            guard record.model != before else { return before }
            try record.update(db)
            try self.audit(
                db, actor, "environment.update",
                project: before.projectID, environment: environmentID, before: before, after: record.model
            )
            return record.model
        }
    }

    /// Doing nothing (archiving an archived environment) isn't recorded.
    @discardableResult
    public func setArchived(_ archived: Bool, environment environmentID: EnvironmentID, by actor: AuditActor) async throws -> Environment {
        try await database.write { db in
            guard var record = try EnvironmentRecord.fetchOne(db, key: environmentID.rawValue) else {
                throw StoreError.notFound("No environment with ID '\(environmentID)'")
            }
            guard (record.archivedAt != nil) != archived else { return record.model }
            let before = record.model
            record.archivedAt = archived ? self.now() : nil
            try record.update(db)
            try self.audit(
                db, actor, archived ? "environment.archive" : "environment.unarchive",
                project: before.projectID, environment: environmentID, before: before, after: record.model
            )
            return record.model
        }
    }

    public func environment(key: String, in projectID: ProjectID) async throws -> Environment? {
        try await database.read { db in
            try EnvironmentRecord.filter(Column("projectID") == projectID.rawValue && Column("key") == key).fetchOne(db)?.model
        }
    }

    // MARK: - Flags

    /// Creates a flag with a disabled config in every environment of the project. `defaultVariant` is what
    /// those configs serve once enabled; without it, it's the first variant name in sorted order.
    @discardableResult
    public func createFlag(
        key: String,
        type: FlagType,
        variants: [String: JSONValue],
        description: String = "",
        isExperiment: Bool = false,
        defaultVariant: String? = nil,
        in projectID: ProjectID,
        by actor: AuditActor
    ) async throws -> Flag {
        let flag = Flag(
            key: key, type: type, variants: variants, description: description, isExperiment: isExperiment,
            createdBy: actor.description, createdAt: now()
        )
        do {
            try flag.validate()
        } catch {
            throw StoreError.invalid(error.issues)
        }
        if let defaultVariant, variants[defaultVariant] == nil {
            throw StoreError.invalid(["Default variant '\(defaultVariant)' isn't one of the flag's variants"])
        }

        let environmentIDs = try await database.write { db in
            try Self.requireProject(projectID, db)
            if try FlagRecord.exists(db, key: ["projectID": projectID.rawValue, "key": key]) {
                throw StoreError.conflict("A flag with key '\(key)' already exists in this project")
            }
            let record = FlagRecord(flag, projectID: projectID)
            try record.insert(db)
            let environmentIDs = try Self.environmentIDs(in: projectID, db)
            for environmentID in environmentIDs {
                try Self.insertDefaultConfig(for: record, variant: defaultVariant, in: environmentID, db)
            }
            try Self.bumpVersions(of: environmentIDs, db)
            try self.audit(db, actor, "flag.create", project: projectID, flagKey: key, after: flag)
            return environmentIDs
        }
        try await refreshSnapshots(environmentIDs)
        return flag
    }

    public func flag(key: String, in projectID: ProjectID) async throws -> Flag? {
        try await database.read { db in
            try FlagRecord.fetchOne(db, key: ["projectID": projectID.rawValue, "key": key])?.model
        }
    }

    /// Sorted by key.
    public func flags(in projectID: ProjectID, includeArchived: Bool = false) async throws -> [Flag] {
        try await database.read { db in
            var request = FlagRecord.filter(Column("projectID") == projectID.rawValue)
            if !includeArchived {
                request = request.filter(Column("archivedAt") == nil)
            }
            return try request.order(Column("key")).fetchAll(db).map(\.model)
        }
    }

    /// Archived flags evaluate as `DISABLED` and are left out of bulk evaluation. Doing nothing (archiving an
    /// archived flag) isn't recorded.
    @discardableResult
    public func setArchived(_ archived: Bool, flagKey: String, in projectID: ProjectID, by actor: AuditActor) async throws -> Flag {
        let (flag, environmentIDs) = try await database.write { db in
            guard var record = try FlagRecord.fetchOne(db, key: ["projectID": projectID.rawValue, "key": flagKey]) else {
                throw StoreError.notFound("No flag with key '\(flagKey)'")
            }
            guard (record.archivedAt != nil) != archived else { return (record.model, [EnvironmentID]()) }

            let before = record.model
            record.archivedAt = archived ? self.now() : nil
            try record.update(db)
            let environmentIDs = try Self.environmentIDs(in: projectID, db)
            try Self.bumpVersions(of: environmentIDs, db)
            try self.audit(
                db, actor, archived ? "flag.archive" : "flag.unarchive",
                project: projectID, flagKey: flagKey, before: before, after: record.model
            )
            return (record.model, environmentIDs)
        }
        try await refreshSnapshots(environmentIDs)
        return flag
    }

    /// What `updateFlag` can change. `nil` leaves a field as it is. A flag's key and type never change.
    public struct FlagChanges: Sendable, Hashable, Codable {
        public var description: String?
        public var variants: [String: JSONValue]?
        public var isExperiment: Bool?

        public init(description: String? = nil, variants: [String: JSONValue]? = nil, isExperiment: Bool? = nil) {
            self.description = description
            self.variants = variants
            self.isExperiment = isExperiment
        }
    }

    /// New variants are checked against every environment's config, so a variant still in use can't be removed.
    @discardableResult
    public func updateFlag(key: String, in projectID: ProjectID, changes: FlagChanges, by actor: AuditActor) async throws -> Flag {
        let (flag, environmentIDs) = try await database.write { db in
            guard var record = try FlagRecord.fetchOne(db, key: ["projectID": projectID.rawValue, "key": key]) else {
                throw StoreError.notFound("No flag with key '\(key)'")
            }
            let before = record.model
            if let description = changes.description { record.description = description }
            if let variants = changes.variants { record.variants = variants }
            if let isExperiment = changes.isExperiment { record.isExperiment = isExperiment }
            let after = record.model
            guard after != before else { return (after, [EnvironmentID]()) }

            var issues: [String] = []
            do {
                try after.validate()
            } catch let error as ValidationError {
                issues += error.issues
            }
            let environments = try EnvironmentRecord.filter(Column("projectID") == projectID.rawValue).fetchAll(db)
            for environment in environments {
                let config = try FlagConfigRecord.fetchOne(db, key: ["environmentID": environment.id, "flagKey": key])?.config
                do {
                    try config?.validate(for: after)
                } catch let error as ValidationError {
                    issues += error.issues.map { "Environment '\(environment.key)': \($0)" }
                }
            }
            if !issues.isEmpty { throw StoreError.invalid(issues) }

            try record.update(db)
            let environmentIDs = environments.map { EnvironmentID($0.id) }
            try Self.bumpVersions(of: environmentIDs, db)
            try self.audit(db, actor, "flag.update", project: projectID, flagKey: key, before: before, after: after)
            return (after, environmentIDs)
        }
        try await refreshSnapshots(environmentIDs)
        return flag
    }

    /// Deletes the flag and its configs everywhere. Apps asking for it get `FLAG_NOT_FOUND` and use their own
    /// default. Archiving is the gentler option.
    public func deleteFlag(key: String, in projectID: ProjectID, by actor: AuditActor) async throws {
        let environmentIDs = try await database.write { db in
            guard let record = try FlagRecord.fetchOne(db, key: ["projectID": projectID.rawValue, "key": key]) else {
                throw StoreError.notFound("No flag with key '\(key)'")
            }
            try record.delete(db)  // configs go with it (ON DELETE CASCADE)
            let environmentIDs = try Self.environmentIDs(in: projectID, db)
            try Self.bumpVersions(of: environmentIDs, db)
            try self.audit(db, actor, "flag.delete", project: projectID, flagKey: key, before: record.model)
            return environmentIDs
        }
        try await refreshSnapshots(environmentIDs)
    }

    // MARK: - Flag configs

    public func config(flagKey: String, in environmentID: EnvironmentID) async throws -> FlagConfig? {
        try await database.read { db in
            try FlagConfigRecord.fetchOne(db, key: ["environmentID": environmentID.rawValue, "flagKey": flagKey])?.config
        }
    }

    /// Replaces a flag's config in one environment. The stored version is always the previous one plus one,
    /// whatever `config.version` says.
    @discardableResult
    public func setConfig(_ config: FlagConfig, flagKey: String, in environmentID: EnvironmentID, by actor: AuditActor) async throws -> FlagConfig {
        let saved = try await database.write { db in
            guard let environment = try EnvironmentRecord.fetchOne(db, key: environmentID.rawValue) else {
                throw StoreError.notFound("No environment with ID '\(environmentID)'")
            }
            guard let flag = try FlagRecord.fetchOne(db, key: ["projectID": environment.projectID, "key": flagKey]) else {
                throw StoreError.notFound("No flag with key '\(flagKey)'")
            }
            do {
                try config.validate(for: flag.model)
            } catch let error as ValidationError {
                throw StoreError.invalid(error.issues)
            }

            let before = try FlagConfigRecord.fetchOne(db, key: ["environmentID": environmentID.rawValue, "flagKey": flagKey])?.config
            var saved = config
            saved.version = (before?.version ?? 0) + 1
            try FlagConfigRecord(environmentID: environmentID.rawValue, projectID: environment.projectID, flagKey: flagKey, config: saved)
                .save(db)
            try Self.bumpVersions(of: [environmentID], db)
            try self.audit(
                db, actor, "flagConfig.update",
                project: ProjectID(environment.projectID), environment: environmentID, flagKey: flagKey,
                before: before, after: saved
            )
            return saved
        }
        try await refreshSnapshots([environmentID])
        return saved
    }

    // MARK: - Tokens

    /// A new token and its secret. The secret is only ever available here; only its hash is stored.
    public struct CreatedToken: Sendable {
        public var token: Token
        public var secret: String
    }

    public func createAdminToken(name: String, by actor: AuditActor) async throws -> CreatedToken {
        try await createToken(kind: .admin, name: name, environmentID: nil, secret: TokenSecret.make(for: .admin), by: actor)
    }

    public func createEvaluationToken(name: String, for environmentID: EnvironmentID, by actor: AuditActor) async throws -> CreatedToken {
        try await createToken(kind: .evaluation, name: name, environmentID: environmentID, secret: TokenSecret.make(for: .evaluation), by: actor)
    }

    /// For seed files, whose tokens are written out in plain text. Does nothing if the token already exists.
    func importEvaluationToken(secret: String, name: String, for environmentID: EnvironmentID, by actor: AuditActor) async throws {
        let exists = try await database.read { db in
            try TokenRecord.filter(Column("hash") == TokenHash.of(secret)).fetchCount(db) > 0
        }
        if !exists {
            _ = try await createToken(kind: .evaluation, name: name, environmentID: environmentID, secret: secret, by: actor)
        }
    }

    private func createToken(
        kind: Token.Kind,
        name: String,
        environmentID: EnvironmentID?,
        secret: String,
        by actor: AuditActor
    ) async throws -> CreatedToken {
        let record = TokenRecord(
            id: self.makeID(),
            hash: TokenHash.of(secret),
            kind: kind,
            scopes: [kind == .admin ? "admin" : "evaluate"],
            name: name,
            environmentID: environmentID?.rawValue,
            createdBy: actor.description,
            createdAt: now()
        )
        try await database.write { db in
            var projectID: ProjectID?
            if let environmentID {
                guard let environment = try EnvironmentRecord.fetchOne(db, key: environmentID.rawValue) else {
                    throw StoreError.notFound("No environment with ID '\(environmentID)'")
                }
                guard try Self.isLive(environmentID, db) else {
                    throw StoreError.conflict("Environment '\(environment.key)' or its project is archived")
                }
                projectID = ProjectID(environment.projectID)
            }
            try record.insert(db)
            // The audit entry describes the token, never its secret or hash.
            try self.audit(db, actor, "token.create", project: projectID, environment: environmentID, after: record.model)
        }
        return CreatedToken(token: record.model, secret: secret)
    }

    /// Oldest first.
    public func tokens() async throws -> [Token] {
        try await database.read { db in
            try TokenRecord.order(Column("createdAt")).fetchAll(db).map(\.model)
        }
    }

    @discardableResult
    public func revokeToken(_ id: TokenID, by actor: AuditActor) async throws -> Token {
        try await database.write { db in
            guard var record = try TokenRecord.fetchOne(db, key: id.rawValue) else {
                throw StoreError.notFound("No token with ID '\(id)'")
            }
            guard record.revokedAt == nil else { return record.model }
            let before = record.model
            record.revokedAt = self.now()
            try record.update(db)
            let projectID = try record.environmentID
                .flatMap { try EnvironmentRecord.fetchOne(db, key: $0) }
                .map { ProjectID($0.projectID) }
            try self.audit(
                db, actor, "token.revoke",
                project: projectID, environment: record.environmentID.map(EnvironmentID.init), before: before, after: record.model
            )
            return record.model
        }
    }

    /// The token with this hash, unless it's unknown or revoked. Records when it was last used.
    public func authenticate(tokenHash: String) async throws -> Token? {
        guard let record = try await database.read({ db in
            try TokenRecord.filter(Column("hash") == tokenHash && Column("revokedAt") == nil).fetchOne(db)
        }) else { return nil }
        try await recordUse(of: record)
        return record.model
    }

    private func recordUse(of record: TokenRecord) async throws {
        let now = now()
        let shouldWrite = tokenLastUsed.withLock { lastWritten in
            if let previous = lastWritten[record.id] ?? record.lastUsedAt, now.timeIntervalSince(previous) < 60 {
                return false
            }
            lastWritten[record.id] = now
            return true
        }
        guard shouldWrite else { return }
        try await database.write { db in
            try db.execute(sql: "UPDATE token SET lastUsedAt = ? WHERE id = ?", arguments: [now, record.id])
        }
    }

    // MARK: - Audit log

    /// Newest first. Every filter is optional. `since` is inclusive, `until` exclusive.
    public func auditEntries(
        projectID: ProjectID? = nil,
        flagKey: String? = nil,
        actor: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 100
    ) async throws -> [AuditEntry] {
        try await database.read { db in
            var request = AuditRecord.all()
            if let projectID { request = request.filter(Column("projectID") == projectID.rawValue) }
            if let flagKey { request = request.filter(Column("flagKey") == flagKey) }
            if let actor { request = request.filter(Column("actor") == actor) }
            if let since { request = request.filter(Column("timestamp") >= since) }
            if let until { request = request.filter(Column("timestamp") < until) }
            return try request.order(Column("id").desc).limit(limit).fetchAll(db).map(\.model)
        }
    }

    private func audit(
        _ db: Database,
        _ actor: AuditActor,
        _ action: String,
        project: ProjectID? = nil,
        environment: EnvironmentID? = nil,
        flagKey: String? = nil,
        before: (any Encodable & Sendable)? = nil,
        after: (any Encodable & Sendable)? = nil
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        func json(_ value: (any Encodable)?) throws -> String? {
            try value.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        }
        var record = AuditRecord(
            timestamp: now(), actor: actor.description, action: action,
            projectID: project?.rawValue, environmentID: environment?.rawValue, flagKey: flagKey,
            before: try json(before), after: try json(after)
        )
        try record.insert(db)
    }

    // MARK: - EvaluationStore

    public func environment(forTokenHash tokenHash: String) async throws -> EnvironmentID? {
        guard let token = try await authenticate(tokenHash: tokenHash), token.kind == .evaluation,
              let environmentID = token.environmentID,
              try await database.read({ db in try Self.isLive(environmentID, db) })
        else { return nil }
        return environmentID
    }

    public func snapshot(for environment: EnvironmentID) async throws -> EnvironmentSnapshot {
        if let cached = snapshots.withLock({ $0[environment] }) {
            return cached
        }
        let loaded = try await database.read { db in try Self.loadSnapshot(environment, db) }
        return cache(loaded, for: environment)
    }

    private func refreshSnapshots(_ environmentIDs: [EnvironmentID]) async throws {
        for environmentID in environmentIDs {
            let loaded = try await database.read { db in try Self.loadSnapshot(environmentID, db) }
            cache(loaded, for: environmentID)
        }
    }

    /// Keeps whichever snapshot is newer. A slow read that started before a write can't overwrite the
    /// fresher snapshot that the write stored, because versions only go up.
    @discardableResult
    private func cache(_ snapshot: EnvironmentSnapshot, for environmentID: EnvironmentID) -> EnvironmentSnapshot {
        snapshots.withLock { cache in
            if let existing = cache[environmentID], existing.version >= snapshot.version {
                return existing
            }
            cache[environmentID] = snapshot
            return snapshot
        }
    }

    private static func loadSnapshot(_ environmentID: EnvironmentID, _ db: Database) throws -> EnvironmentSnapshot {
        guard let environment = try EnvironmentRecord.fetchOne(db, key: environmentID.rawValue) else {
            return EnvironmentSnapshot(version: 0, entries: [])
        }
        let flags = try FlagRecord.filter(Column("projectID") == environment.projectID).fetchAll(db)
        let configs = try FlagConfigRecord.filter(Column("environmentID") == environmentID.rawValue).fetchAll(db)
        let configsByKey = Dictionary(uniqueKeysWithValues: configs.map { ($0.flagKey, $0.config) })
        let entries = flags.compactMap { flag in
            configsByKey[flag.key].map { EnvironmentSnapshot.Entry(flag: flag.model, config: $0) }
        }
        return EnvironmentSnapshot(version: environment.version, entries: entries)
    }

    // MARK: - Helpers

    private static func requireValidKey(_ key: String, kind: String) throws {
        guard Flag.isValidKey(key) else {
            throw StoreError.invalid(["\(kind) key '\(key)' must be 1–\(Flag.maxKeyLength) characters from A–Z, a–z, 0–9, '.', '_', '-'"])
        }
    }

    private static func requireProject(_ projectID: ProjectID, _ db: Database) throws {
        if try !ProjectRecord.exists(db, key: projectID.rawValue) {
            throw StoreError.notFound("No project with ID '\(projectID)'")
        }
    }

    /// The environment and its project both exist and aren't archived.
    private static func isLive(_ environmentID: EnvironmentID, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT 1 FROM environment JOIN project ON project.id = environment.projectID
            WHERE environment.id = ? AND environment.archivedAt IS NULL AND project.archivedAt IS NULL
            """, arguments: [environmentID.rawValue]) ?? false
    }

    private static func environmentIDs(in projectID: ProjectID, _ db: Database) throws -> [EnvironmentID] {
        try String.fetchAll(db, sql: "SELECT id FROM environment WHERE projectID = ?", arguments: [projectID.rawValue])
            .map(EnvironmentID.init)
    }

    private static func bumpVersions(of environmentIDs: [EnvironmentID], _ db: Database) throws {
        for environmentID in environmentIDs {
            try db.execute(sql: "UPDATE environment SET version = version + 1 WHERE id = ?", arguments: [environmentID.rawValue])
        }
    }

    /// New flags and environments start disabled. The default variant only matters once someone enables the
    /// flag; unless given, it's the first variant name in sorted order (so boolean on/off flags get `off`).
    private static func insertDefaultConfig(
        for flag: FlagRecord,
        variant: String? = nil,
        in environmentID: EnvironmentID,
        _ db: Database
    ) throws {
        let firstVariant = variant ?? flag.variants.keys.sorted().first ?? ""
        try FlagConfigRecord(
            environmentID: environmentID.rawValue,
            projectID: flag.projectID,
            flagKey: flag.key,
            config: FlagConfig(enabled: false, defaultResult: .variant(firstVariant))
        ).insert(db)
    }
}
