/// How a flag behaves in one environment.
public struct FlagConfig: Sendable, Hashable, Codable {
    /// When `false`, evaluation returns `DISABLED` and the app uses its own default.
    public var enabled: Bool
    /// Checked in order. The first rule whose conditions all match wins.
    public var rules: [Rule]
    /// Used when no rule matches.
    public var defaultResult: RuleResult
    /// Goes up by one on every change.
    public var version: Int

    public init(enabled: Bool, rules: [Rule] = [], defaultResult: RuleResult, version: Int = 1) {
        self.enabled = enabled
        self.rules = rules
        self.defaultResult = defaultResult
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, rules, defaultResult, version
    }

    /// `rules` and `version` are optional in JSON. The server assigns versions, so clients don't send one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decode(Bool.self, forKey: .enabled),
            rules: try container.decodeIfPresent([Rule].self, forKey: .rules) ?? [],
            defaultResult: try container.decode(RuleResult.self, forKey: .defaultResult),
            version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        )
    }
}

public struct Rule: Sendable, Hashable, Codable {
    /// All must match. An empty list always matches.
    public var conditions: [Condition]
    public var result: RuleResult

    public init(conditions: [Condition], result: RuleResult) {
        self.conditions = conditions
        self.result = result
    }
}

/// What a rule (or the default) hands out.
///
/// JSON: `{"variant": "on"}` or `{"rollout": [{"variant": "on", "weight": 1000}, ...]}`.
public enum RuleResult: Sendable, Hashable {
    case variant(String)
    /// Weights are out of `Bucketing.bucketCount` (10,000), so 1,000 is 10%.
    case rollout([WeightedVariant])
}

extension RuleResult {
    /// Shorthand for `.rollout([WeightedVariant])`: `.rollout(["on": 1_000, "off": 9_000])`.
    /// Order matters (it decides which buckets each variant gets), so this takes `KeyValuePairs`, not a dictionary.
    public static func rollout(_ weights: KeyValuePairs<String, Int>) -> Self {
        .rollout(weights.map { WeightedVariant(variant: $0.key, weight: $0.value) })
    }
}

public struct WeightedVariant: Sendable, Hashable, Codable {
    public var variant: String
    public var weight: Int

    public init(variant: String, weight: Int) {
        self.variant = variant
        self.weight = weight
    }
}

extension RuleResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case variant, rollout
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch (container.contains(.variant), container.contains(.rollout)) {
        case (true, false):
            self = .variant(try container.decode(String.self, forKey: .variant))
        case (false, true):
            self = .rollout(try container.decode([WeightedVariant].self, forKey: .rollout))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected exactly one of 'variant' or 'rollout'")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .variant(let variant): try container.encode(variant, forKey: .variant)
        case .rollout(let entries): try container.encode(entries, forKey: .rollout)
        }
    }
}
