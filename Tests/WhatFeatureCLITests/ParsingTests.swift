import Testing
import WhatFeatureCore
import WhatFeatureServer
@testable import whatfeature

@Suite struct VariantParsingTests {
    @Test func followsTheFlagType() throws {
        #expect(try parseVariants(["on=true", "off=false"], type: .boolean) == ["on": true, "off": false])
        #expect(try parseVariants(["greeting=Hello there", "empty="], type: .string) == ["greeting": "Hello there", "empty": ""])
        #expect(try parseVariants(["low=1", "high=2.5"], type: .number) == ["low": 1, "high": 2.5])
        #expect(try parseVariants([##"dark={"bg": "#000"}"##], type: .object) == ["dark": ["bg": "#000"]])
        // Only the first '=' splits, so values can contain '='.
        #expect(try parseVariants(["eq=a=b"], type: .string) == ["eq": "a=b"])
    }

    @Test(arguments: [
        (["on=yes"], FlagType.boolean),
        (["n=ten"], .number),
        (["o=not json"], .object),
        (["noequals"], .string),
        (["=value"], .string),
        (["a=1", "a=2"], .string),
    ])
    func rejects(_ assignments: [String], _ type: FlagType) {
        #expect(throws: (any Error).self) { try parseVariants(assignments, type: type) }
    }
}

@Suite struct RolloutParsingTests {
    @Test func percentagesBecomeWeights() throws {
        #expect(try parseRollout(["on=10", "off=90"]) == [.init(variant: "on", weight: 1_000), .init(variant: "off", weight: 9_000)])
        #expect(try parseRollout(["a=12.5%", "b=87.5"]) == [.init(variant: "a", weight: 1_250), .init(variant: "b", weight: 8_750)])
        #expect(try parseRollout(["a=0.01", "b=99.99"]).map(\.weight) == [1, 9_999])
    }

    @Test(arguments: ["on=-1", "on=101", "on=lots", "on=0.001"])
    func rejects(_ share: String) {
        #expect(throws: (any Error).self) { try parseRollout([share]) }
    }
}

@Suite struct ContextParsingTests {
    /// The reason --attr is always a string: `2.0` must stay a version, not become a number.
    @Test func attributesStayStrings() throws {
        let context = try buildContext(json: nil, targetingKey: "user-1", attributes: ["appVersion=2.0", "beta=true"], jsonAttributes: [])
        #expect(context.targetingKey == "user-1")
        #expect(context.attributes == ["appVersion": "2.0", "beta": "true"])
    }

    @Test func jsonAttributesAreTyped() throws {
        let context = try buildContext(json: nil, targetingKey: nil, attributes: [], jsonAttributes: ["age=30", "beta=true"])
        #expect(context.attributes == ["age": 30, "beta": true])
    }

    @Test func flagsAddToTheJSONContext() throws {
        let context = try buildContext(
            json: #"{"targetingKey": "a", "country": "US"}"#, targetingKey: "b", attributes: ["plan=pro"], jsonAttributes: []
        )
        #expect(context.targetingKey == "b")
        #expect(context.attributes == ["country": "US", "plan": "pro"])
    }

    @Test func rejectsBadContextJSON() {
        #expect(throws: (any Error).self) {
            try buildContext(json: "[1, 2]", targetingKey: nil, attributes: [], jsonAttributes: [])
        }
    }
}

@Suite struct OutputTests {
    @Test func percentages() {
        #expect(percent(1_000) == "10%")
        #expect(percent(1_250) == "12.5%")
        #expect(percent(1) == "0.01%")
    }

    @Test func configSummary() {
        #expect(summary(of: FlagConfig(enabled: true, defaultResult: .variant("off"))) == "off")
        #expect(summary(of: FlagConfig(
            enabled: true,
            rules: [Rule(conditions: [], result: .variant("on"))],
            defaultResult: .rollout(["on": 1_000, "off": 9_000])
        )) == "1 rule, then 10% on / 90% off")
    }
}

@Suite struct RateLimitParsingTests {
    @Test func perMinuteOrOff() throws {
        #expect(try parseRateLimit("600") == RateLimit(requestsPerMinute: 600))
        #expect(try parseRateLimit("off") == nil)
        #expect(try parseRateLimit("OFF") == nil)
    }

    @Test(arguments: ["0", "-5", "1.5", "lots", ""])
    func rejects(_ text: String) {
        #expect(throws: (any Error).self) { try parseRateLimit(text) }
    }
}
