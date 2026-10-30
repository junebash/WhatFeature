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
        case membership(Membership)
        case string(StringMatch)
        case number(Comparison, Double)
        case version(Comparison, SemanticVersion)
        case presence(Presence)
    }

    /// `equals` / `notEquals`: compares the whole JSON value.
    public struct Equality: Sendable, Hashable {
        public var value: JSONValue
        /// `true` for `equals`, `false` for `notEquals`.
        public var isEqual: Bool

        public init(_ value: JSONValue, isEqual: Bool = true) {
            self.value = value
            self.isEqual = isEqual
        }

        func matches(_ attribute: JSONValue) -> Bool {
            (attribute == value) == isEqual
        }
    }

    /// `in` / `notIn`: checks the value against a list.
    public struct Membership: Sendable, Hashable {
        public var values: [JSONValue]
        /// `true` for `in`, `false` for `notIn`.
        public var isMember: Bool

        public init(_ values: [JSONValue], isMember: Bool = true) {
            self.values = values
            self.isMember = isMember
        }

        func matches(_ attribute: JSONValue) -> Bool {
            values.contains(attribute) == isMember
        }
    }

    /// `startsWith` / `endsWith` / `contains` on a string attribute.
    public struct StringMatch: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case startsWith
            case endsWith
            case contains
        }

        public var kind: Kind
        public var string: String

        public init(_ kind: Kind, _ string: String) {
            self.kind = kind
            self.string = string
        }

        func matches(_ attribute: String) -> Bool {
            switch kind {
            case .startsWith: attribute.hasPrefix(string)
            case .endsWith: attribute.hasSuffix(string)
            case .contains: attribute.contains(string)
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

    /// `exists` / `notExists`.
    public struct Presence: Sendable, Hashable {
        /// `true` for `exists`, `false` for `notExists`.
        public var isPresent: Bool

        public init(isPresent: Bool) {
            self.isPresent = isPresent
        }
    }
}

/// Shorthands named after the JSON operators, e.g. `.notIn(["US", "CA"])` or `.exists`.
extension Condition.Predicate {
    public static func equals(_ value: JSONValue) -> Self { .equality(.init(value)) }
    public static func notEquals(_ value: JSONValue) -> Self { .equality(.init(value, isEqual: false)) }

    public static func `in`(_ values: [JSONValue]) -> Self { .membership(.init(values)) }
    public static func notIn(_ values: [JSONValue]) -> Self { .membership(.init(values, isMember: false)) }

    public static func startsWith(_ string: String) -> Self { .string(.init(.startsWith, string)) }
    public static func endsWith(_ string: String) -> Self { .string(.init(.endsWith, string)) }
    public static func contains(_ string: String) -> Self { .string(.init(.contains, string)) }

    public static let exists: Self = .presence(.init(isPresent: true))
    public static let notExists: Self = .presence(.init(isPresent: false))
}

extension Condition {
    /// If the attribute is missing (or `null`), the condition is false for every operator except `notExists`.
    /// A value of the wrong type (e.g. `lt` on a string) is also false, not an error.
    public func matches(_ context: EvaluationContext) -> Bool {
        guard let value = context.value(for: attribute) else {
            return predicate == .notExists
        }

        switch predicate {
        case .presence(let presence): return presence.isPresent
        case .equality(let equality): return equality.matches(value)
        case .membership(let membership): return membership.matches(value)
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
        func noValue() throws(InvalidOperand) {
            if operand != nil { throw InvalidOperand(message: "'\(op.rawValue)' doesn't take a value") }
        }

        switch op {
        case .equals: self = .equals(try required())
        case .notEquals: self = .notEquals(try required())
        case .in: self = .in(try list())
        case .notIn: self = .notIn(try list())
        case .startsWith: self = .startsWith(try string())
        case .endsWith: self = .endsWith(try string())
        case .contains: self = .contains(try string())
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
            try noValue()
            self = .exists
        case .notExists:
            try noValue()
            self = .notExists
        }
    }

    var `operator`: Condition.Operator {
        switch self {
        case .equality(let equality): equality.isEqual ? .equals : .notEquals
        case .membership(let membership): membership.isMember ? .in : .notIn
        case .string(let match):
            switch match.kind {
            case .startsWith: .startsWith
            case .endsWith: .endsWith
            case .contains: .contains
            }
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
        case .presence(let presence): presence.isPresent ? .exists : .notExists
        }
    }

    var operand: JSONValue? {
        switch self {
        case .equality(let equality): equality.value
        case .membership(let membership): .array(membership.values)
        case .string(let match): .string(match.string)
        case .number(_, let number): .number(number)
        case .version(_, let version): .string(version.description)
        case .presence: nil
        }
    }
}
