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

extension Condition {
    /// The test to run on the attribute's value, grouped by the kind of value it compares.
    public enum Predicate: Sendable, Hashable {
        case equality(Equality)
        case string(StringMatch)
        case number(Comparison, Double)
        case version(Comparison, SemanticVersion)
        case exists
        case notExists
    }

    /// Compares the whole JSON value.
    public enum Equality: Sendable, Hashable {
        case equals(JSONValue)
        case notEquals(JSONValue)
        case `in`([JSONValue])
        case notIn([JSONValue])

        func matches(_ value: JSONValue) -> Bool {
            switch self {
            case .equals(let expected): value == expected
            case .notEquals(let expected): value != expected
            case .in(let list): list.contains(value)
            case .notIn(let list): !list.contains(value)
            }
        }
    }

    public enum StringMatch: Sendable, Hashable {
        case startsWith(String)
        case endsWith(String)
        case contains(String)

        func matches(_ string: String) -> Bool {
            switch self {
            case .startsWith(let prefix): string.hasPrefix(prefix)
            case .endsWith(let suffix): string.hasSuffix(suffix)
            case .contains(let substring): string.contains(substring)
            }
        }
    }

    /// Used for both numbers and semantic versions. The attribute's value is on the left:
    /// `.number(.lt, 18)` means "attribute < 18".
    public enum Comparison: Sendable, Hashable {
        case eq
        case lt
        case lte
        case gt
        case gte

        func holds<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool {
            switch self {
            case .eq: lhs == rhs
            case .lt: lhs < rhs
            case .lte: lhs <= rhs
            case .gt: lhs > rhs
            case .gte: lhs >= rhs
            }
        }
    }
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
        case .equality(let equality): return equality.matches(value)
        case .string(let match): return value.stringValue.map(match.matches) ?? false
        case .number(let comparison, let number):
            return value.numberValue.map { comparison.holds($0, number) } ?? false
        case .version(let comparison, let version):
            return value.stringValue.flatMap(SemanticVersion.init).map { comparison.holds($0, version) } ?? false
        }
    }
}

// MARK: - JSON

extension Condition {
    /// Operator names as they appear in JSON.
    public enum Operator: String, Sendable, Hashable, Codable, CaseIterable {
        case equals, notEquals, `in`, notIn
        case startsWith, endsWith, contains
        case eq, lt, lte, gt, gte
        case semverEq, semverLt, semverLte, semverGt, semverGte
        case exists, notExists
    }
}

extension Condition: Codable {
    /// Mirrors the JSON shape. The typed `Predicate` is built from (or flattened into) this.
    private struct Wire: Codable {
        var attribute: String
        var `operator`: Operator
        var value: JSONValue?
    }

    public init(from decoder: any Decoder) throws {
        let wire = try Wire(from: decoder)
        do {
            self.init(wire.attribute, try Predicate(wire.operator, operand: wire.value))
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.message))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try Wire(attribute: attribute, operator: predicate.operator, value: predicate.operand).encode(to: encoder)
    }
}

struct InvalidOperand: Error {
    var message: String
}

extension Condition.Predicate {
    init(_ op: Condition.Operator, operand: JSONValue?) throws(InvalidOperand) {
        func required() throws(InvalidOperand) -> JSONValue {
            guard let operand else { throw InvalidOperand(message: "'\(op.rawValue)' needs a value") }
            return operand
        }
        func list() throws(InvalidOperand) -> [JSONValue] {
            guard case .array(let list) = try required() else { throw InvalidOperand(message: "'\(op.rawValue)' needs a list") }
            return list
        }
        func string() throws(InvalidOperand) -> String {
            guard let string = try required().stringValue else { throw InvalidOperand(message: "'\(op.rawValue)' needs a string") }
            return string
        }
        func number() throws(InvalidOperand) -> Double {
            guard let number = try required().numberValue else { throw InvalidOperand(message: "'\(op.rawValue)' needs a number") }
            return number
        }
        func version() throws(InvalidOperand) -> SemanticVersion {
            let string = try string()
            guard let version = SemanticVersion(string) else { throw InvalidOperand(message: "'\(string)' is not a valid version") }
            return version
        }
        func none() throws(InvalidOperand) {
            if operand != nil { throw InvalidOperand(message: "'\(op.rawValue)' doesn't take a value") }
        }

        switch op {
        case .equals: self = .equality(.equals(try required()))
        case .notEquals: self = .equality(.notEquals(try required()))
        case .in: self = .equality(.in(try list()))
        case .notIn: self = .equality(.notIn(try list()))
        case .startsWith: self = .string(.startsWith(try string()))
        case .endsWith: self = .string(.endsWith(try string()))
        case .contains: self = .string(.contains(try string()))
        case .eq: self = .number(.eq, try number())
        case .lt: self = .number(.lt, try number())
        case .lte: self = .number(.lte, try number())
        case .gt: self = .number(.gt, try number())
        case .gte: self = .number(.gte, try number())
        case .semverEq: self = .version(.eq, try version())
        case .semverLt: self = .version(.lt, try version())
        case .semverLte: self = .version(.lte, try version())
        case .semverGt: self = .version(.gt, try version())
        case .semverGte: self = .version(.gte, try version())
        case .exists:
            try none()
            self = .exists
        case .notExists:
            try none()
            self = .notExists
        }
    }

    var `operator`: Condition.Operator {
        switch self {
        case .equality(.equals): .equals
        case .equality(.notEquals): .notEquals
        case .equality(.in): .in
        case .equality(.notIn): .notIn
        case .string(.startsWith): .startsWith
        case .string(.endsWith): .endsWith
        case .string(.contains): .contains
        case .number(.eq, _): .eq
        case .number(.lt, _): .lt
        case .number(.lte, _): .lte
        case .number(.gt, _): .gt
        case .number(.gte, _): .gte
        case .version(.eq, _): .semverEq
        case .version(.lt, _): .semverLt
        case .version(.lte, _): .semverLte
        case .version(.gt, _): .semverGt
        case .version(.gte, _): .semverGte
        case .exists: .exists
        case .notExists: .notExists
        }
    }

    var operand: JSONValue? {
        switch self {
        case .equality(.equals(let value)), .equality(.notEquals(let value)): value
        case .equality(.in(let list)), .equality(.notIn(let list)): .array(list)
        case .string(.startsWith(let string)), .string(.endsWith(let string)), .string(.contains(let string)): .string(string)
        case .number(_, let number): .number(number)
        case .version(_, let version): .string(version.description)
        case .exists, .notExists: nil
        }
    }
}
