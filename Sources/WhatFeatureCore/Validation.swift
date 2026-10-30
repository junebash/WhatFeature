/// Everything wrong with a flag or config, so the admin API can report all problems at once.
public struct ValidationError: Error, Sendable, Hashable, CustomStringConvertible {
    public var issues: [String]

    public init(issues: [String]) {
        self.issues = issues
    }

    public var description: String {
        issues.joined(separator: "\n")
    }
}

extension Flag {
    public static let maxKeyLength = 128

    /// 1–128 characters from `A–Z a–z 0–9 . _ -`. Keys appear in URLs, so nothing fancier.
    /// Variant names follow the same rule.
    public static func isValidKey(_ key: String) -> Bool {
        (1...maxKeyLength).contains(key.count)
            && key.allSatisfy { $0.isASCIIDigit || $0.isASCIILetter || $0 == "." || $0 == "_" || $0 == "-" }
    }

    public func validate() throws(ValidationError) {
        var issues: [String] = []
        if !Self.isValidKey(key) {
            issues.append("Flag key '\(key)' must be 1–\(Self.maxKeyLength) characters from A–Z, a–z, 0–9, '.', '_', '-'")
        }
        if variants.isEmpty {
            issues.append("A flag needs at least one variant")
        }
        for (name, value) in variants.sorted(by: { $0.key < $1.key }) {
            if !Self.isValidKey(name) {
                issues.append("Variant name '\(name)' must be 1–\(Self.maxKeyLength) characters from A–Z, a–z, 0–9, '.', '_', '-'")
            }
            if !type.accepts(value) {
                issues.append("Variant '\(name)' doesn't match the flag type '\(type.rawValue)'")
            }
        }
        if !issues.isEmpty { throw ValidationError(issues: issues) }
    }
}

extension FlagConfig {
    public func validate(for flag: Flag) throws(ValidationError) {
        var issues: [String] = []

        func check(_ result: RuleResult, at location: String) {
            switch result {
            case .variant(let variant):
                if flag.variants[variant] == nil {
                    issues.append("\(location): unknown variant '\(variant)'")
                }
            case .rollout(let rollout):
                if rollout.isEmpty {
                    issues.append("\(location): a rollout needs at least one variant")
                }
                for entry in rollout {
                    if flag.variants[entry.variant] == nil {
                        issues.append("\(location): unknown variant '\(entry.variant)'")
                    }
                    if entry.weight < 0 {
                        issues.append("\(location): weight for '\(entry.variant)' can't be negative")
                    }
                }
                let total = rollout.reduce(0) { $0 + $1.weight }
                if total != Bucketing.bucketCount {
                    issues.append("\(location): weights add up to \(total), not \(Bucketing.bucketCount)")
                }
            }
        }

        for (ruleIndex, rule) in rules.enumerated() {
            let location = "Rule \(ruleIndex)"
            for (conditionIndex, condition) in rule.conditions.enumerated() {
                if condition.attribute.isEmpty {
                    issues.append("\(location), condition \(conditionIndex): attribute can't be empty")
                }
                if condition.predicate == .equals(.null) || condition.predicate == .notEquals(.null) {
                    issues.append("\(location), condition \(conditionIndex): compare with null using exists/notExists")
                }
            }
            check(rule.result, at: location)
        }
        check(defaultResult, at: "Default")

        if !issues.isEmpty { throw ValidationError(issues: issues) }
    }
}
