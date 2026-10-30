import Foundation

public enum FlagType: String, Sendable, Hashable, Codable, CaseIterable {
    case boolean
    case string
    case number
    case object

    public func accepts(_ value: JSONValue) -> Bool {
        switch (self, value) {
        case (.boolean, .bool), (.string, .string), (.number, .number), (.object, .object): true
        default: false
        }
    }
}

/// A flag and its possible values. Shared by every environment in a project; per-environment
/// behavior lives in `FlagConfig`.
public struct Flag: Sendable, Hashable, Codable {
    /// Unique within a project. Never changes.
    public var key: String
    /// Never changes after creation. Make a new flag instead.
    public var type: FlagType
    /// Named values, e.g. `["on": true, "off": false]`.
    public var variants: [String: JSONValue]
    public var description: String
    /// Marks the flag as an A/B test. Doesn't change evaluation.
    public var isExperiment: Bool
    /// ID of the token that created the flag.
    public var createdBy: String
    public var createdAt: Date
    /// Archived flags evaluate as disabled.
    public var archivedAt: Date?

    public init(
        key: String,
        type: FlagType,
        variants: [String: JSONValue],
        description: String = "",
        isExperiment: Bool = false,
        createdBy: String,
        createdAt: Date,
        archivedAt: Date? = nil
    ) {
        self.key = key
        self.type = type
        self.variants = variants
        self.description = description
        self.isExperiment = isExperiment
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    public var isArchived: Bool { archivedAt != nil }
}
