import Foundation
import GRDB
import WhatFeatureCore

// Row types, one per table. They stay internal so GRDB doesn't leak into the public API.
// GRDB stores nested Codable values (variants, config, scopes) as JSON text.

struct ProjectRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project"
    var id: String
    var key: String
    var name: String
    var createdAt: Date

    init(_ project: Project) {
        id = project.id.rawValue
        key = project.key
        name = project.name
        createdAt = project.createdAt
    }

    var model: Project {
        Project(id: ProjectID(id), key: key, name: name, createdAt: createdAt)
    }
}

struct EnvironmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "environment"
    var id: String
    var projectID: String
    var key: String
    var name: String
    var version: Int
    var createdAt: Date

    init(_ environment: Environment) {
        id = environment.id.rawValue
        projectID = environment.projectID.rawValue
        key = environment.key
        name = environment.name
        version = environment.version
        createdAt = environment.createdAt
    }

    var model: Environment {
        Environment(id: EnvironmentID(id), projectID: ProjectID(projectID), key: key, name: name, version: version, createdAt: createdAt)
    }
}

struct FlagRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "flag"
    var projectID: String
    var key: String
    var type: FlagType
    var variants: [String: JSONValue]
    var description: String
    var isExperiment: Bool
    var createdBy: String
    var createdAt: Date
    var archivedAt: Date?

    init(_ flag: Flag, projectID: ProjectID) {
        self.projectID = projectID.rawValue
        key = flag.key
        type = flag.type
        variants = flag.variants
        description = flag.description
        isExperiment = flag.isExperiment
        createdBy = flag.createdBy
        createdAt = flag.createdAt
        archivedAt = flag.archivedAt
    }

    var model: Flag {
        Flag(
            key: key, type: type, variants: variants, description: description, isExperiment: isExperiment,
            createdBy: createdBy, createdAt: createdAt, archivedAt: archivedAt
        )
    }
}

struct FlagConfigRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "flagConfig"
    var environmentID: String
    var projectID: String
    var flagKey: String
    var config: FlagConfig
}

struct TokenRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "token"
    var id: String
    var hash: String
    var kind: Token.Kind
    var scopes: [String]
    var name: String
    var environmentID: String?
    var createdBy: String
    var createdAt: Date
    var lastUsedAt: Date?
    var revokedAt: Date?

    var model: Token {
        Token(
            id: TokenID(id), kind: kind, scopes: scopes, name: name, environmentID: environmentID.map(EnvironmentID.init),
            createdBy: createdBy, createdAt: createdAt, lastUsedAt: lastUsedAt, revokedAt: revokedAt
        )
    }
}

struct AuditRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "auditEntry"
    var id: Int64?
    var timestamp: Date
    var actor: String
    var action: String
    var projectID: String?
    var environmentID: String?
    var flagKey: String?
    var before: String?
    var after: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var model: AuditEntry {
        AuditEntry(
            id: id ?? 0, timestamp: timestamp, actor: actor, action: action,
            projectID: projectID.map(ProjectID.init), environmentID: environmentID.map(EnvironmentID.init),
            flagKey: flagKey, before: before, after: after
        )
    }
}
