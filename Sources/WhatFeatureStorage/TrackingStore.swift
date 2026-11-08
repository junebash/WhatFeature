public import Foundation
import GRDB
public import WhatFeatureCore

/// One OFREP request with a targeting key, as tracking records it.
public struct Sighting: Sendable, Hashable {
    public var environmentID: EnvironmentID
    public var targetingKey: String
    /// Only the attributes the environment's `TrackingSettings` allow. The store keeps whatever it's given.
    public var attributes: [String: JSONValue]
    public var time: Date
    /// Resolved results only. Empty for a `304`, which served nothing new.
    public var served: [Served]

    public init(environmentID: EnvironmentID, targetingKey: String, attributes: [String: JSONValue], time: Date, served: [Served]) {
        self.environmentID = environmentID
        self.targetingKey = targetingKey
        self.attributes = attributes
        self.time = time
        self.served = served
    }

    public struct Served: Sendable, Hashable {
        public var flagKey: String
        public var variant: String
        public var reason: Reason
        /// `nil` for the default.
        public var matchedRule: Int?
        /// The flag config's version.
        public var configVersion: Int

        public init(flagKey: String, variant: String, reason: Reason, matchedRule: Int?, configVersion: Int) {
            self.flagKey = flagKey
            self.variant = variant
            self.reason = reason
            self.matchedRule = matchedRule
            self.configVersion = configVersion
        }
    }
}

/// A targeting key the server has seen in one environment.
public struct SeenContext: Sendable, Hashable, Codable {
    public var environmentID: EnvironmentID
    public var targetingKey: String
    public var firstSeen: Date
    public var lastSeen: Date
    /// From the latest request.
    public var attributes: [String: JSONValue]
}

/// One variant of one flag served to one targeting key. A key that moves to another variant gets another exposure.
public struct Exposure: Sendable, Hashable, Codable {
    public var environmentID: EnvironmentID
    public var targetingKey: String
    public var flagKey: String
    public var variant: String
    public var firstServed: Date
    public var lastServed: Date
    /// `reason`, `matchedRule` and `configVersion` are from the latest time it was served.
    public var reason: Reason
    public var matchedRule: Int?
    public var configVersion: Int
}

/// Who the server saw and what it served them, for environments with tracking on.
///
/// A separate database file from `SQLiteStore`: SQLite has one writer per file, so tracking writes never wait on
/// admin writes, and the file can be thrown away without touching flags. Applying `TrackingSettings` (which
/// attributes, how long) is up to the caller: `record` stores what it's given, and `enforce` deletes what the
/// settings no longer allow.
public final class TrackingStore: Sendable {
    private let database: any DatabaseWriter
    private let now: @Sendable () -> Date

    /// Opens (or creates) a database file and brings its schema up to date.
    ///
    /// - Parameter now: The clock `enforce` measures retention against.
    public convenience init(path: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try self.init(database: DatabasePool(path: path), now: now)
    }

    /// A database that lives only as long as this object. For tests and quick local runs.
    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() }) throws -> TrackingStore {
        try TrackingStore(database: DatabaseQueue(), now: now)
    }

    private init(database: any DatabaseWriter, now: @escaping @Sendable () -> Date) throws {
        self.database = database
        self.now = now
        try Self.migrator.migrate(database)
    }

    /// Writes a batch in one transaction. Sightings can arrive in any order: first and last times are the earliest
    /// and latest seen, and attributes and exposure details come from the latest.
    public func record(_ sightings: [Sighting]) async throws {
        guard !sightings.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let rows = try sightings.map { ($0, String(decoding: try encoder.encode($0.attributes), as: UTF8.self)) }
        try await database.write { db in
            // In an upsert, every expression on the right reads the row as it was before the update.
            let seen = try db.cachedStatement(sql: """
                INSERT INTO seenContext (environmentID, targetingKey, firstSeen, lastSeen, attributes) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (environmentID, targetingKey) DO UPDATE SET
                    firstSeen = min(firstSeen, excluded.firstSeen),
                    lastSeen = max(lastSeen, excluded.lastSeen),
                    attributes = CASE WHEN excluded.lastSeen >= lastSeen THEN excluded.attributes ELSE attributes END
                """)
            let served = try db.cachedStatement(sql: """
                INSERT INTO exposure (environmentID, targetingKey, flagKey, variant, firstServed, lastServed, reason, matchedRule, configVersion)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (environmentID, targetingKey, flagKey, variant) DO UPDATE SET
                    firstServed = min(firstServed, excluded.firstServed),
                    lastServed = max(lastServed, excluded.lastServed),
                    reason = CASE WHEN excluded.lastServed >= lastServed THEN excluded.reason ELSE reason END,
                    matchedRule = CASE WHEN excluded.lastServed >= lastServed THEN excluded.matchedRule ELSE matchedRule END,
                    configVersion = CASE WHEN excluded.lastServed >= lastServed THEN excluded.configVersion ELSE configVersion END
                """)
            for (sighting, attributes) in rows {
                let environmentID = sighting.environmentID.rawValue
                try seen.execute(arguments: [environmentID, sighting.targetingKey, sighting.time, sighting.time, attributes])
                for result in sighting.served {
                    try served.execute(arguments: [
                        environmentID, sighting.targetingKey, result.flagKey, result.variant, sighting.time, sighting.time,
                        result.reason.rawValue, result.matchedRule, result.configVersion,
                    ])
                }
            }
        }
    }

    /// Most recently seen first. `since` is inclusive.
    public func seenContexts(in environmentID: EnvironmentID, since: Date? = nil, limit: Int = 100) async throws -> [SeenContext] {
        try await database.read { db in
            var request = SeenContextRecord.filter(Column("environmentID") == environmentID.rawValue)
            if let since { request = request.filter(Column("lastSeen") >= since) }
            return try request.order(Column("lastSeen").desc, Column("targetingKey")).limit(limit).fetchAll(db).map(\.model)
        }
    }

    public func seenContext(_ targetingKey: String, in environmentID: EnvironmentID) async throws -> SeenContext? {
        try await database.read { db in
            try SeenContextRecord.fetchOne(db, key: ["environmentID": environmentID.rawValue, "targetingKey": targetingKey])?.model
        }
    }

    /// Sorted by targeting key, flag, then when first served. Both filters are optional.
    public func exposures(in environmentID: EnvironmentID, targetingKey: String? = nil, flagKey: String? = nil) async throws -> [Exposure] {
        try await database.read { db in
            var request = ExposureRecord.filter(Column("environmentID") == environmentID.rawValue)
            if let targetingKey { request = request.filter(Column("targetingKey") == targetingKey) }
            if let flagKey { request = request.filter(Column("flagKey") == flagKey) }
            return try request.order(Column("targetingKey"), Column("flagKey"), Column("firstServed")).fetchAll(db).map(\.model)
        }
    }

    /// Deletes everything stored for one targeting key in one environment. Returns whether there was anything.
    @discardableResult
    public func deleteContext(_ targetingKey: String, in environmentID: EnvironmentID) async throws -> Bool {
        try await database.write { db in
            // Exposures go with it (ON DELETE CASCADE).
            try SeenContextRecord.deleteOne(db, key: ["environmentID": environmentID.rawValue, "targetingKey": targetingKey])
        }
    }

    /// Deletes what each environment's settings no longer allow: contexts not seen within `retentionDays` (with their
    /// exposures), and attributes not in `attributes`. Applies whether tracking is on or off, so data stored before
    /// it was turned off still expires. Environments missing from `settings` are left alone.
    public func enforce(_ settings: [EnvironmentID: TrackingSettings]) async throws {
        let now = now()
        try await database.write { db in
            for (environmentID, settings) in settings {
                let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86_400)
                try db.execute(
                    sql: "DELETE FROM seenContext WHERE environmentID = ? AND lastSeen < ?",
                    arguments: [environmentID.rawValue, cutoff]
                )

                let allowed = settings.attributes
                let disallowedKey = allowed.isEmpty ? "1" : "key NOT IN (\(databaseQuestionMarks(count: allowed.count)))"
                let stale = try SeenContextRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM seenContext WHERE environmentID = ?
                        AND EXISTS (SELECT 1 FROM json_each(attributes) WHERE \(disallowedKey))
                        """,
                    arguments: StatementArguments([environmentID.rawValue] + allowed)
                )
                for var record in stale {
                    record.attributes = record.attributes.filter { allowed.contains($0.key) }
                    try record.update(db)
                }
            }
        }
    }

    // MARK: - Schema

    /// Migrations run every time the store opens. Never edit a shipped migration; add a new one.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "seenContext") { t in
                t.column("environmentID", .text).notNull()
                t.column("targetingKey", .text).notNull()
                t.column("firstSeen", .datetime).notNull()
                t.column("lastSeen", .datetime).notNull()
                t.column("attributes", .jsonText).notNull()
                t.primaryKey(["environmentID", "targetingKey"])
            }
            try db.create(index: "seenContext_on_environmentID_lastSeen", on: "seenContext", columns: ["environmentID", "lastSeen"])

            try db.create(table: "exposure") { t in
                t.column("environmentID", .text).notNull()
                t.column("targetingKey", .text).notNull()
                t.column("flagKey", .text).notNull()
                t.column("variant", .text).notNull()
                t.column("firstServed", .datetime).notNull()
                t.column("lastServed", .datetime).notNull()
                t.column("reason", .text).notNull()
                t.column("matchedRule", .integer)
                t.column("configVersion", .integer).notNull()
                t.primaryKey(["environmentID", "targetingKey", "flagKey", "variant"])
                t.foreignKey(
                    ["environmentID", "targetingKey"], references: "seenContext", columns: ["environmentID", "targetingKey"],
                    onDelete: .cascade
                )
            }
            try db.create(index: "exposure_on_environmentID_flagKey", on: "exposure", columns: ["environmentID", "flagKey"])
        }
        return migrator
    }
}

// MARK: - Records

private struct SeenContextRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "seenContext"
    var environmentID: String
    var targetingKey: String
    var firstSeen: Date
    var lastSeen: Date
    var attributes: [String: JSONValue]

    var model: SeenContext {
        SeenContext(
            environmentID: EnvironmentID(environmentID), targetingKey: targetingKey, firstSeen: firstSeen, lastSeen: lastSeen,
            attributes: attributes
        )
    }
}

private struct ExposureRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "exposure"
    var environmentID: String
    var targetingKey: String
    var flagKey: String
    var variant: String
    var firstServed: Date
    var lastServed: Date
    var reason: Reason
    var matchedRule: Int?
    var configVersion: Int

    var model: Exposure {
        Exposure(
            environmentID: EnvironmentID(environmentID), targetingKey: targetingKey, flagKey: flagKey, variant: variant,
            firstServed: firstServed, lastServed: lastServed, reason: reason, matchedRule: matchedRule, configVersion: configVersion
        )
    }
}
