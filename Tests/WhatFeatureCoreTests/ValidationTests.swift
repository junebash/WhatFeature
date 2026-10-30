import Foundation
import Testing
import WhatFeatureCore

@Suite struct ValidationTests {
    @Test func acceptsAValidFlag() throws {
        try Flag.boolean().validate()
    }

    @Test(arguments: ["new-onboarding", "checkout.v2", "A_B-test", String(repeating: "a", count: 128)])
    func acceptsKey(_ key: String) {
        #expect(Flag.isValidKey(key))
    }

    @Test(arguments: ["", "has space", "slash/key", "émoji", String(repeating: "a", count: 129)])
    func rejectsKey(_ key: String) {
        #expect(!Flag.isValidKey(key))
    }

    @Test func reportsEveryFlagProblem() throws {
        let flag = Flag(key: "bad key", type: .boolean, variants: ["on": "yes"], createdBy: "t", createdAt: Date())
        let error = try #require(throws: ValidationError.self) { try flag.validate() }
        #expect(error.issues.count == 2)
    }

    @Test func rejectsFlagWithoutVariants() throws {
        let flag = Flag(key: "empty", type: .string, variants: [:], createdBy: "t", createdAt: Date())
        #expect(throws: ValidationError.self) { try flag.validate() }
    }

    @Test func acceptsAValidConfig() throws {
        let config = FlagConfig(
            enabled: true,
            rules: [Rule(conditions: [Condition("country", .equality(.equals("US")))], result: .variant("on"))],
            defaultResult: .rollout([.init(variant: "on", weight: 2_500), .init(variant: "off", weight: 7_500)])
        )
        try config.validate(for: .boolean())
    }

    @Test func rejectsUnknownVariants() throws {
        let config = FlagConfig(
            enabled: true,
            rules: [Rule(conditions: [], result: .variant("maybe"))],
            defaultResult: .rollout([.init(variant: "nope", weight: 10_000)])
        )
        let error = try #require(throws: ValidationError.self) { try config.validate(for: .boolean()) }
        #expect(error.issues == ["Rule 0: unknown variant 'maybe'", "Default: unknown variant 'nope'"])
    }

    @Test func rejectsWeightsThatDontAddUp() throws {
        let config = FlagConfig(enabled: true, defaultResult: .rollout([.init(variant: "on", weight: 1_000)]))
        let error = try #require(throws: ValidationError.self) { try config.validate(for: .boolean()) }
        #expect(error.issues == ["Default: weights add up to 1000, not 10000"])
    }

    @Test func rejectsNegativeWeightsAndEmptyRollouts() throws {
        let negative = FlagConfig(
            enabled: true,
            defaultResult: .rollout([.init(variant: "on", weight: -1), .init(variant: "off", weight: 10_001)])
        )
        #expect(throws: ValidationError.self) { try negative.validate(for: .boolean()) }

        let empty = FlagConfig(enabled: true, defaultResult: .rollout([]))
        #expect(throws: ValidationError.self) { try empty.validate(for: .boolean()) }
    }

    @Test func rejectsNullComparisonsAndEmptyAttributes() throws {
        let config = FlagConfig(
            enabled: true,
            rules: [Rule(conditions: [Condition("country", .equality(.equals(nil))), Condition("", .exists)], result: .variant("on"))],
            defaultResult: .variant("off")
        )
        let error = try #require(throws: ValidationError.self) { try config.validate(for: .boolean()) }
        #expect(error.issues.count == 2)
    }
}
