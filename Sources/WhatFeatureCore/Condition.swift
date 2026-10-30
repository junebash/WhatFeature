/// One test against one context attribute, e.g. "appVersion semverGte 2.1.0".
///
/// JSON: `{"attribute": "appVersion", "operator": "semverGte", "value": "2.1.0"}`.
/// `exists` and `notExists` take no `value`.
public struct Condition: Sendable, Hashable {
    public var attribute: String
    public var predicate: Predicate

    public init(_ attribute: String, _ predicate: Predicate) {
        self.attribute = attribute
        self.predicate = predicate
    }
}

/// The operator and its operand. Case names match the operator names used in JSON.
public enum Predicate: Sendable, Hashable {
    case equals(JSONValue)
    case notEquals(JSONValue)
    case `in`([JSONValue])
    case notIn([JSONValue])

    case startsWith(String)
    case endsWith(String)
    case contains(String)

    case lt(Double)
    case lte(Double)
    case gt(Double)
    case gte(Double)

    case semverEq(SemanticVersion)
    case semverLt(SemanticVersion)
    case semverLte(SemanticVersion)
    case semverGt(SemanticVersion)
    case semverGte(SemanticVersion)

    case exists
    case notExists
}

extension Condition {
    /// If the attribute is missing (or `null`), the condition is false for every operator except `notExists`.
    /// A value of the wrong type (e.g. `lt` on a string) is also false, not an error.
    public func matches(_ context: EvaluationContext) -> Bool {
        guard let value = context.value(for: attribute) else {
            return predicate == .notExists
        }

        switch predicate {
        case .exists: return true
        case .notExists: return false

        case .equals(let expected): return value == expected
        case .notEquals(let expected): return value != expected
        case .in(let list): return list.contains(value)
        case .notIn(let list): return !list.contains(value)

        case .startsWith(let prefix): return value.stringValue?.hasPrefix(prefix) ?? false
        case .endsWith(let suffix): return value.stringValue?.hasSuffix(suffix) ?? false
        case .contains(let substring): return value.stringValue?.contains(substring) ?? false

        case .lt(let number): return value.numberValue.map { $0 < number } ?? false
        case .lte(let number): return value.numberValue.map { $0 <= number } ?? false
        case .gt(let number): return value.numberValue.map { $0 > number } ?? false
        case .gte(let number): return value.numberValue.map { $0 >= number } ?? false

        case .semverEq(let version): return value.semanticVersion.map { $0 == version } ?? false
        case .semverLt(let version): return value.semanticVersion.map { $0 < version } ?? false
        case .semverLte(let version): return value.semanticVersion.map { $0 <= version } ?? false
        case .semverGt(let version): return value.semanticVersion.map { $0 > version } ?? false
        case .semverGte(let version): return value.semanticVersion.map { $0 >= version } ?? false
        }
    }
}

extension JSONValue {
    fileprivate var semanticVersion: SemanticVersion? {
        stringValue.flatMap(SemanticVersion.init)
    }
}

extension Condition: Codable {
    private enum CodingKeys: String, CodingKey {
        case attribute, `operator`, value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attribute = try container.decode(String.self, forKey: .attribute)
        let name = try container.decode(String.self, forKey: .operator)

        func value<T: Decodable>(_: T.Type = T.self) throws -> T {
            try container.decode(T.self, forKey: .value)
        }

        let predicate: Predicate = switch name {
        case "equals": .equals(try value())
        case "notEquals": .notEquals(try value())
        case "in": .in(try value())
        case "notIn": .notIn(try value())
        case "startsWith": .startsWith(try value())
        case "endsWith": .endsWith(try value())
        case "contains": .contains(try value())
        case "lt": .lt(try value())
        case "lte": .lte(try value())
        case "gt": .gt(try value())
        case "gte": .gte(try value())
        case "semverEq": .semverEq(try value())
        case "semverLt": .semverLt(try value())
        case "semverLte": .semverLte(try value())
        case "semverGt": .semverGt(try value())
        case "semverGte": .semverGte(try value())
        case "exists": .exists
        case "notExists": .notExists
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .operator, in: container, debugDescription: "Unknown operator '\(name)'"
            )
        }
        self.init(attribute, predicate)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attribute, forKey: .attribute)
        try container.encode(predicate.name, forKey: .operator)
        switch predicate {
        case .equals(let value), .notEquals(let value): try container.encode(value, forKey: .value)
        case .in(let list), .notIn(let list): try container.encode(list, forKey: .value)
        case .startsWith(let string), .endsWith(let string), .contains(let string):
            try container.encode(string, forKey: .value)
        case .lt(let number), .lte(let number), .gt(let number), .gte(let number):
            try container.encode(number, forKey: .value)
        case .semverEq(let version), .semverLt(let version), .semverLte(let version),
             .semverGt(let version), .semverGte(let version):
            try container.encode(version, forKey: .value)
        case .exists, .notExists:
            break
        }
    }
}

extension Predicate {
    /// The operator name used in JSON.
    public var name: String {
        switch self {
        case .equals: "equals"
        case .notEquals: "notEquals"
        case .in: "in"
        case .notIn: "notIn"
        case .startsWith: "startsWith"
        case .endsWith: "endsWith"
        case .contains: "contains"
        case .lt: "lt"
        case .lte: "lte"
        case .gt: "gt"
        case .gte: "gte"
        case .semverEq: "semverEq"
        case .semverLt: "semverLt"
        case .semverLte: "semverLte"
        case .semverGt: "semverGt"
        case .semverGte: "semverGte"
        case .exists: "exists"
        case .notExists: "notExists"
        }
    }
}
