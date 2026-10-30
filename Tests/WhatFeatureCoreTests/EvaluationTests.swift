import Testing
import WhatFeatureCore

@Suite struct EvaluationTests {
    let user = EvaluationContext(targetingKey: "user-123", attributes: ["country": "US", "appVersion": "2.1.0"])

    @Test func unknownFlagIsNotFound() {
        let snapshot = EnvironmentSnapshot(version: 1, entries: [])
        let result = snapshot.evaluate(flagKey: "nope", context: user)
        #expect(result.outcome == .error(.flagNotFound, details: "No flag with key 'nope'"))
    }

    @Test func wrongExpectedTypeIsMismatch() {
        let snapshot = EnvironmentSnapshot.single(.boolean(), FlagConfig(enabled: true, defaultResult: .variant("on")))
        let result = snapshot.evaluate(flagKey: "new-onboarding", context: user, expectedType: .string)
        #expect(result.reason == .error)
        guard case .error(.typeMismatch, _) = result.outcome else {
            Issue.record("Expected TYPE_MISMATCH, got \(result.outcome)")
            return
        }
    }

    @Test func disabledFlagIsDisabled() {
        let snapshot = EnvironmentSnapshot.single(.boolean(), FlagConfig(enabled: false, defaultResult: .variant("on")))
        #expect(snapshot.evaluate(flagKey: "new-onboarding", context: user).outcome == .disabled)
    }

    @Test func archivedFlagIsDisabled() {
        let snapshot = EnvironmentSnapshot.single(.boolean(archived: true), FlagConfig(enabled: true, defaultResult: .variant("on")))
        #expect(snapshot.evaluate(flagKey: "new-onboarding", context: user).outcome == .disabled)
    }

    @Test func flagWithoutRulesIsStatic() {
        let snapshot = EnvironmentSnapshot.single(.boolean(), FlagConfig(enabled: true, defaultResult: .variant("on")))
        let result = snapshot.evaluate(flagKey: "new-onboarding", context: user)
        #expect(result.outcome == .resolved(value: true, variant: "on", reason: .static, matchedRule: nil))
    }

    @Test func firstMatchingRuleWins() {
        let config = FlagConfig(
            enabled: true,
            rules: [
                Rule(conditions: [Condition("country", .equals("DE"))], result: .variant("off")),
                Rule(conditions: [Condition("country", .equals("US"))], result: .variant("on")),
                Rule(conditions: [], result: .variant("off")),
            ],
            defaultResult: .variant("off")
        )
        let result = EnvironmentSnapshot.single(.boolean(), config).evaluate(flagKey: "new-onboarding", context: user)
        #expect(result.outcome == .resolved(value: true, variant: "on", reason: .targetingMatch, matchedRule: 1))
    }

    @Test func allConditionsInARuleMustMatch() {
        let config = FlagConfig(
            enabled: true,
            rules: [Rule(
                conditions: [Condition("country", .equals("US")), Condition("appVersion", .version(.gte, SemanticVersion(major: 3)))],
                result: .variant("on")
            )],
            defaultResult: .variant("off")
        )
        let result = EnvironmentSnapshot.single(.boolean(), config).evaluate(flagKey: "new-onboarding", context: user)
        #expect(result.outcome == .resolved(value: false, variant: "off", reason: .default, matchedRule: nil))
    }

    @Test func rolloutRuleIsSplit() {
        // user-123 is in bucket 323 for new-onboarding (see BucketingTests), so 10% includes them.
        let config = FlagConfig(
            enabled: true,
            rules: [Rule(conditions: [], result: .rollout(["on": 1_000, "off": 9_000]))],
            defaultResult: .variant("off")
        )
        let result = EnvironmentSnapshot.single(.boolean(), config).evaluate(flagKey: "new-onboarding", context: user)
        #expect(result.outcome == .resolved(value: true, variant: "on", reason: .split, matchedRule: 0))
    }

    @Test func rolloutRuleIsSkippedWithoutTargetingKey() {
        let config = FlagConfig(
            enabled: true,
            rules: [Rule(conditions: [], result: .rollout(["on": 10_000]))],
            defaultResult: .variant("off")
        )
        let anonymous = EvaluationContext(attributes: ["country": "US"])
        let result = EnvironmentSnapshot.single(.boolean(), config).evaluate(flagKey: "new-onboarding", context: anonymous)
        #expect(result.outcome == .resolved(value: false, variant: "off", reason: .default, matchedRule: nil))
    }

    @Test func rolloutDefaultWithoutTargetingKeyIsAnError() {
        let config = FlagConfig(enabled: true, defaultResult: .rollout(["on": 10_000]))
        let result = EnvironmentSnapshot.single(.boolean(), config).evaluate(flagKey: "new-onboarding", context: EvaluationContext())
        guard case .error(.targetingKeyMissing, _) = result.outcome else {
            Issue.record("Expected TARGETING_KEY_MISSING, got \(result.outcome)")
            return
        }
    }

    @Test func undefinedVariantIsAGeneralError() {
        let config = FlagConfig(enabled: true, defaultResult: .variant("maybe"))
        let result = EnvironmentSnapshot.single(.boolean(), config).evaluate(flagKey: "new-onboarding", context: user)
        #expect(result.outcome == .error(.general, details: "Variant 'maybe' is not defined"))
    }

    @Test func evaluateAllSkipsArchivedAndSortsByKey() {
        let on = FlagConfig(enabled: true, defaultResult: .variant("on"))
        let snapshot = EnvironmentSnapshot(version: 1, entries: [
            .init(flag: .boolean("zebra"), config: on),
            .init(flag: .boolean("apple"), config: on),
            .init(flag: .boolean("old", archived: true), config: on),
        ])
        #expect(snapshot.evaluateAll(context: user).map(\.flagKey) == ["apple", "zebra"])
    }

    @Test func decodesConfigFromJSON() throws {
        let json = """
        {
          "enabled": true,
          "version": 3,
          "rules": [
            {
              "conditions": [{"attribute": "appVersion", "operator": "semverGte", "value": "2.0"}],
              "result": {"rollout": [{"variant": "on", "weight": 5000}, {"variant": "off", "weight": 5000}]}
            }
          ],
          "defaultResult": {"variant": "off"}
        }
        """
        let config = try decode(FlagConfig.self, from: json)
        #expect(config == FlagConfig(
            enabled: true,
            rules: [Rule(
                conditions: [Condition("appVersion", .version(.gte, SemanticVersion(major: 2)))],
                result: .rollout(["on": 5_000, "off": 5_000])
            )],
            defaultResult: .variant("off"),
            version: 3
        ))
        #expect(try roundTrip(config) == config)
    }

    @Test func rejectsAmbiguousRuleResult() {
        #expect(throws: DecodingError.self) {
            try decode(RuleResult.self, from: #"{"variant": "on", "rollout": []}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(RuleResult.self, from: "{}")
        }
    }

    @Test func rolloutShorthandKeepsOrder() {
        #expect(RuleResult.rollout(["off": 9_000, "on": 1_000]) == .rollout([
            WeightedVariant(variant: "off", weight: 9_000),
            WeightedVariant(variant: "on", weight: 1_000),
        ]))
    }
}
