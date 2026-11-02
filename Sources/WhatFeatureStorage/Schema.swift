import GRDB

enum Schema {
    /// Migrations run every time the store opens. Never edit a shipped migration; add a new one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("key", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "environment") { t in
                t.primaryKey("id", .text)
                t.column("projectID", .text).notNull().references("project", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("name", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["projectID", "key"])
            }

            try db.create(table: "flag") { t in
                t.column("projectID", .text).notNull().references("project", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("type", .text).notNull()
                t.column("variants", .jsonText).notNull()
                t.column("description", .text).notNull()
                t.column("isExperiment", .boolean).notNull()
                t.column("createdBy", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("archivedAt", .datetime)
                t.primaryKey(["projectID", "key"])
            }

            try db.create(table: "flagConfig") { t in
                t.column("environmentID", .text).notNull().references("environment", onDelete: .cascade)
                t.column("projectID", .text).notNull()
                t.column("flagKey", .text).notNull()
                // The whole FlagConfig (enabled, rules, default, version) as JSON. Rules are nested and
                // always read together, so separate tables would add joins for nothing.
                t.column("config", .jsonText).notNull()
                t.primaryKey(["environmentID", "flagKey"])
                t.foreignKey(["projectID", "flagKey"], references: "flag", columns: ["projectID", "key"], onDelete: .cascade)
            }

            try db.create(table: "token") { t in
                t.primaryKey("id", .text)
                t.column("hash", .text).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("scopes", .jsonText).notNull()
                t.column("name", .text).notNull()
                t.column("environmentID", .text).references("environment", onDelete: .cascade)
                t.column("createdBy", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime)
                t.column("revokedAt", .datetime)
            }

            // No foreign keys: audit entries outlive the things they describe.
            try db.create(table: "auditEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull()
                t.column("actor", .text).notNull()
                t.column("action", .text).notNull()
                t.column("projectID", .text)
                t.column("environmentID", .text)
                t.column("flagKey", .text)
                t.column("before", .jsonText)
                t.column("after", .jsonText)
            }
            try db.create(index: "auditEntry_on_projectID_flagKey", on: "auditEntry", columns: ["projectID", "flagKey"])
        }

        // Projects and environments are archived, never deleted.
        migrator.registerMigration("v2-archive-projects-and-environments") { db in
            try db.alter(table: "project") { t in t.add(column: "archivedAt", .datetime) }
            try db.alter(table: "environment") { t in t.add(column: "archivedAt", .datetime) }
        }

        return migrator
    }
}
