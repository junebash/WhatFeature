/// Why a flag resolved the way it did. Raw values are the OpenFeature names.
public enum Reason: String, Sendable, Hashable, Codable {
    /// The flag has no rules; everyone gets the default variant.
    case `static` = "STATIC"
    /// A rule matched and handed out a fixed variant.
    case targetingMatch = "TARGETING_MATCH"
    /// The variant came from a percentage rollout.
    case split = "SPLIT"
    /// The flag has rules, but none matched.
    case `default` = "DEFAULT"
    /// The flag is turned off or archived. The app should use its own default.
    case disabled = "DISABLED"
    case error = "ERROR"
}

/// OFREP / OpenFeature error codes. Raw values are the wire names.
public enum EvaluationErrorCode: String, Sendable, Hashable, Codable {
    case flagNotFound = "FLAG_NOT_FOUND"
    case typeMismatch = "TYPE_MISMATCH"
    case targetingKeyMissing = "TARGETING_KEY_MISSING"
    case invalidContext = "INVALID_CONTEXT"
    case parseError = "PARSE_ERROR"
    case general = "GENERAL"
}

public struct EvaluationResult: Sendable, Hashable {
    public var flagKey: String
    public var outcome: Outcome

    public enum Outcome: Sendable, Hashable {
        /// `matchedRule` is the index of the rule that matched, or `nil` for the default.
        case resolved(value: JSONValue, variant: String, reason: Reason, matchedRule: Int?)
        case disabled
        case error(EvaluationErrorCode, details: String)
    }

    public init(flagKey: String, outcome: Outcome) {
        self.flagKey = flagKey
        self.outcome = outcome
    }

    public var reason: Reason {
        switch outcome {
        case .resolved(_, _, let reason, _): reason
        case .disabled: .disabled
        case .error: .error
        }
    }
}

/// Every flag in one environment, as an immutable value. The server keeps one per environment in
/// memory and swaps in a new one when something changes, so evaluation never touches the database.
public struct EnvironmentSnapshot: Sendable, Hashable {
    /// Goes up whenever any flag in the environment changes.
    public var version: Int
    /// Keyed by flag key.
    public var entries: [String: Entry]

    public struct Entry: Sendable, Hashable {
        public var flag: Flag
        public var config: FlagConfig

        public init(flag: Flag, config: FlagConfig) {
            self.flag = flag
            self.config = config
        }
    }

    public init(version: Int, entries: [Entry]) {
        self.version = version
        self.entries = Dictionary(entries.map { ($0.flag.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Evaluates one flag. Pass `expectedType` when the caller knows what type it wants, to get
    /// `TYPE_MISMATCH` instead of a value of the wrong type.
    public func evaluate(
        flagKey: String,
        context: EvaluationContext,
        expectedType: FlagType? = nil
    ) -> EvaluationResult {
        guard let entry = entries[flagKey] else {
            return EvaluationResult(
                flagKey: flagKey,
                outcome: .error(.flagNotFound, details: "No flag with key '\(flagKey)'")
            )
        }
        if let expectedType, expectedType != entry.flag.type {
            return EvaluationResult(
                flagKey: flagKey,
                outcome: .error(.typeMismatch, details: "Flag is \(entry.flag.type.rawValue), not \(expectedType.rawValue)")
            )
        }
        return entry.evaluate(context: context)
    }

    /// Evaluates every non-archived flag, sorted by key. This backs OFREP's bulk endpoint.
    public func evaluateAll(context: EvaluationContext) -> [EvaluationResult] {
        entries.values
            .filter { !$0.flag.isArchived }
            .sorted { $0.flag.key < $1.flag.key }
            .map { $0.evaluate(context: context) }
    }
}

extension EnvironmentSnapshot.Entry {
    public func evaluate(context: EvaluationContext) -> EvaluationResult {
        EvaluationResult(flagKey: flag.key, outcome: outcome(for: context))
    }

    private func outcome(for context: EvaluationContext) -> EvaluationResult.Outcome {
        guard config.enabled, !flag.isArchived else { return .disabled }

        for (index, rule) in config.rules.enumerated()
        where rule.conditions.allSatisfy({ $0.matches(context) }) {
            switch resolve(rule.result, fixedReason: .targetingMatch, context: context) {
            case .variant(let variant, let reason):
                return resolved(variant, reason: reason, matchedRule: index)
            case .targetingKeyMissing:
                // A rollout can't bucket without a targeting key, so skip it and keep looking.
                continue
            case .invalid(let details):
                return .error(.general, details: details)
            }
        }

        let defaultReason: Reason = config.rules.isEmpty ? .static : .default
        switch resolve(config.defaultResult, fixedReason: defaultReason, context: context) {
        case .variant(let variant, let reason):
            return resolved(variant, reason: reason, matchedRule: nil)
        case .targetingKeyMissing:
            return .error(.targetingKeyMissing, details: "The default is a rollout, which needs a targetingKey")
        case .invalid(let details):
            return .error(.general, details: details)
        }
    }

    private enum Resolution {
        case variant(String, Reason)
        case targetingKeyMissing
        case invalid(String)
    }

    private func resolve(_ result: RuleResult, fixedReason: Reason, context: EvaluationContext) -> Resolution {
        switch result {
        case .variant(let variant):
            return .variant(variant, fixedReason)
        case .rollout(let rollout):
            guard let targetingKey = context.targetingKey else { return .targetingKeyMissing }
            let bucket = Bucketing.bucket(flagKey: flag.key, targetingKey: targetingKey)
            guard let variant = Bucketing.variant(for: bucket, in: rollout) else {
                return .invalid("Rollout weights don't cover bucket \(bucket)")
            }
            return .variant(variant, .split)
        }
    }

    private func resolved(_ variant: String, reason: Reason, matchedRule: Int?) -> EvaluationResult.Outcome {
        guard let value = flag.variants[variant] else {
            return .error(.general, details: "Variant '\(variant)' is not defined")
        }
        return .resolved(value: value, variant: variant, reason: reason, matchedRule: matchedRule)
    }
}
