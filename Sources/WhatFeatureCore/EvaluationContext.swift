/// What an app tells us about the user or device when it asks for a flag value.
///
/// On the wire (OFREP) this is one flat JSON object, with `targetingKey` alongside the other attributes.
public struct EvaluationContext: Sendable, Hashable {
    /// Stable ID used for percentage rollouts, e.g. a user ID or device ID. An empty string counts as missing.
    public var targetingKey: String? {
        didSet { if targetingKey?.isEmpty == true { targetingKey = nil } }
    }

    public var attributes: [String: JSONValue]

    public init(targetingKey: String? = nil, attributes: [String: JSONValue] = [:]) {
        self.targetingKey = targetingKey?.isEmpty == true ? nil : targetingKey
        self.attributes = attributes
    }

    /// Looks up an attribute by name. `targetingKey` can be used as an attribute name too.
    ///
    /// Returns `nil` when the attribute is missing or `null`; rules treat both the same way.
    public func value(for attribute: String) -> JSONValue? {
        if attribute == "targetingKey" {
            return targetingKey.map(JSONValue.string)
        }
        guard let value = attributes[attribute], value != .null else { return nil }
        return value
    }
}

extension EvaluationContext: Codable {
    public init(from decoder: any Decoder) throws {
        var attributes = try [String: JSONValue](from: decoder)
        let targetingKey: String?
        switch attributes.removeValue(forKey: "targetingKey") {
        case nil, .null:
            targetingKey = nil
        case .string(let value):
            targetingKey = value
        case .some:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "targetingKey must be a string")
            )
        }
        self.init(targetingKey: targetingKey, attributes: attributes)
    }

    public func encode(to encoder: any Encoder) throws {
        var object = attributes
        if let targetingKey {
            object["targetingKey"] = .string(targetingKey)
        }
        try object.encode(to: encoder)
    }
}
