public import Foundation

/// IDs are plain strings in JSON (`"3f2a…"`), not `{"rawValue": …}`.
public protocol StringIdentifier: Sendable, Hashable, Codable, CustomStringConvertible {
    var rawValue: String { get }
    init(_ rawValue: String)
}

extension StringIdentifier {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct ProjectID: StringIdentifier {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct EnvironmentID: StringIdentifier {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct TokenID: StringIdentifier {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A group of flags, usually one app or service.
public struct Project: Sendable, Hashable, Codable {
    public var id: ProjectID
    /// Unique. Used in admin API paths.
    public var key: String
    public var name: String
    public var createdAt: Date
}

/// One place a project runs, like `dev` or `prod`. Each flag has a separate config per environment.
public struct Environment: Sendable, Hashable, Codable {
    public var id: EnvironmentID
    public var projectID: ProjectID
    /// Unique within the project.
    public var key: String
    public var name: String
    /// Goes up whenever any flag in the environment changes. Becomes the snapshot version, and so feeds the ETag.
    public var version: Int
    public var createdAt: Date
}

public struct Token: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Can use the admin API.
        case admin
        /// Can evaluate flags in one environment. Assume it's public: anything shipped in an app can be extracted.
        case evaluation
    }

    public var id: TokenID
    public var kind: Kind
    /// Only `admin` and `evaluate` exist today. A list from the start, so roles can be added later
    /// without a schema change.
    public var scopes: [String]
    public var name: String
    /// Set for evaluation tokens.
    public var environmentID: EnvironmentID?
    public var createdBy: String
    public var createdAt: Date
    /// Updated at most once a minute.
    public var lastUsedAt: Date?
    public var revokedAt: Date?

    public var isRevoked: Bool { revokedAt != nil }
}

/// Who made a change, as recorded in the audit log and `Flag.createdBy`.
public enum AuditActor: Sendable, Hashable, CustomStringConvertible {
    case token(TokenID)
    /// The server or CLI itself, e.g. `system("seed")` or `system("cli")`.
    case system(String)

    public var description: String {
        switch self {
        case .token(let id): "token:\(id.rawValue)"
        case .system(let name): "system:\(name)"
        }
    }
}

/// One admin change. Written in the same transaction as the change, and never edited.
public struct AuditEntry: Sendable, Hashable, Codable {
    public var id: Int64
    public var timestamp: Date
    /// `AuditActor.description`, e.g. `token:…` or `system:seed`.
    public var actor: String
    /// e.g. `project.create`, `flag.create`, `flagConfig.update`, `token.revoke`.
    public var action: String
    public var projectID: ProjectID?
    public var environmentID: EnvironmentID?
    public var flagKey: String?
    /// JSON of the thing before and after the change. `nil` for creates and deletes respectively.
    public var before: String?
    public var after: String?
}

public enum StoreError: Error, Sendable, Hashable, CustomStringConvertible {
    case notFound(String)
    case conflict(String)
    case invalid([String])

    public var description: String {
        switch self {
        case .notFound(let message), .conflict(let message): message
        case .invalid(let issues): issues.joined(separator: "\n")
        }
    }
}
