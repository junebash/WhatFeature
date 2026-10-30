import Foundation
import Testing
import WhatFeatureCore

@Suite struct ConditionTests {
    let context = EvaluationContext(
        targetingKey: "user-1",
        attributes: [
            "country": "US",
            "email": "june@example.com",
            "age": 30,
            "appVersion": "2.1.0",
            "beta": true,
        ]
    )

    @Test(arguments: [
        (Condition("country", .equals("US")), true),
        (Condition("country", .equals("DE")), false),
        (Condition("country", .notEquals("DE")), true),
        (Condition("country", .in(["US", "CA"])), true),
        (Condition("country", .notIn(["US", "CA"])), false),
        (Condition("beta", .equals(true)), true),
        (Condition("targetingKey", .in(["user-1", "user-2"])), true),

        (Condition("email", .startsWith("june@")), true),
        (Condition("email", .endsWith("@example.com")), true),
        (Condition("email", .contains("example")), true),
        (Condition("email", .endsWith("@other.com")), false),

        (Condition("age", .number(.eq, 30)), true),
        (Condition("age", .number(.lt, 30)), false),
        (Condition("age", .number(.lte, 30)), true),
        (Condition("age", .number(.gt, 18)), true),
        (Condition("age", .number(.gte, 31)), false),

        (Condition("appVersion", .version(.eq, SemanticVersion(major: 2, minor: 1))), true),
        (Condition("appVersion", .version(.lt, SemanticVersion(major: 10))), true),
        (Condition("appVersion", .version(.lte, SemanticVersion(major: 2))), false),
        (Condition("appVersion", .version(.gt, SemanticVersion(major: 2))), true),
        (Condition("appVersion", .version(.gte, SemanticVersion(major: 2, minor: 2))), false),

        (Condition("country", .exists), true),
        (Condition("country", .notExists), false),
    ])
    func matches(_ condition: Condition, _ expected: Bool) {
        #expect(condition.matches(context) == expected)
    }

    @Test(arguments: [
        Condition.Predicate.equals("US"), .notEquals("US"), .in(["US"]), .notIn(["US"]),
        .startsWith("U"), .endsWith("S"), .contains("U"),
        .number(.lt, 1), .number(.lte, 1), .number(.gt, 1), .number(.gte, 1),
        .version(.eq, SemanticVersion(major: 1)), .version(.lt, SemanticVersion(major: 1)),
        .version(.lte, SemanticVersion(major: 1)), .version(.gt, SemanticVersion(major: 1)),
        .version(.gte, SemanticVersion(major: 1)),
        .exists,
    ])
    func missingAttributeNeverMatches(_ predicate: Condition.Predicate) {
        #expect(!Condition("missing", predicate).matches(context))
    }

    @Test func missingAttributeMatchesNotExists() {
        #expect(Condition("missing", .notExists).matches(context))
    }

    @Test(arguments: [
        Condition("age", .startsWith("3")),
        Condition("country", .number(.lt, 5)),
        Condition("age", .version(.gt, SemanticVersion(major: 1))),
        Condition("email", .version(.gt, SemanticVersion(major: 1))),
    ])
    func wrongTypeDoesNotMatch(_ condition: Condition) {
        #expect(!condition.matches(context))
    }

    @Test func decodesFromJSON() throws {
        let condition = try decode(Condition.self, from: #"{"attribute": "appVersion", "operator": "semverGte", "value": "2.1"}"#)
        #expect(condition == Condition("appVersion", .version(.gte, SemanticVersion(major: 2, minor: 1))))

        let exists = try decode(Condition.self, from: #"{"attribute": "beta", "operator": "exists"}"#)
        #expect(exists == Condition("beta", .exists))
    }

    @Test(arguments: [
        #"{"attribute": "a", "operator": "matches", "value": ".*"}"#,
        #"{"attribute": "a", "operator": "lt", "value": "five"}"#,
        #"{"attribute": "a", "operator": "semverGt", "value": "not-a-version"}"#,
        #"{"attribute": "a", "operator": "in", "value": "US"}"#,
        #"{"attribute": "a", "operator": "equals"}"#,
        #"{"attribute": "a", "operator": "equals", "value": null}"#,
        #"{"attribute": "a", "operator": "exists", "value": true}"#,
    ])
    func rejectsBadJSON(_ json: String) {
        #expect(throws: DecodingError.self) {
            try decode(Condition.self, from: json)
        }
    }

    @Test(arguments: [
        Condition("a", .equals(["nested": [1, 2]])), Condition("a", .notIn(["x", 3])),
        Condition("a", .contains("x")), Condition("a", .number(.gte, 1.5)),
        Condition("a", .version(.lt, SemanticVersion(major: 1, prerelease: ["rc", "1"]))),
        Condition("a", .notExists),
    ])
    func roundTrips(_ condition: Condition) throws {
        #expect(try roundTrip(condition) == condition)
    }

    @Test(arguments: Condition.Operator.allCases)
    func roundTripsEveryOperator(_ op: Condition.Operator) throws {
        let value: String? = switch op {
        case .equals, .notEquals, .startsWith, .endsWith, .contains: #""x""#
        case .in, .notIn: #"["x"]"#
        case .eq, .lt, .lte, .gt, .gte: "1"
        case .semverEq, .semverLt, .semverLte, .semverGt, .semverGte: #""1.2.3""#
        case .exists, .notExists: nil
        }
        let json = #"{"attribute": "a", "operator": "\#(op.rawValue)""# + (value.map { #", "value": \#($0)}"# } ?? "}")
        let condition = try decode(Condition.self, from: json)

        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(condition))
        guard case .object(let object) = encoded else {
            Issue.record("Expected an object, got \(encoded)")
            return
        }
        #expect(object["operator"] == .string(op.rawValue))
        #expect(try roundTrip(condition) == condition)
    }

    @Test func shorthandsExpandToTheGroupedTypes() {
        typealias Predicate = Condition.Predicate
        #expect(Predicate.equals("US") == .equality(.init("US", isEqual: true)))
        #expect(Predicate.notEquals("US") == .equality(.init("US", isEqual: false)))
        #expect(Predicate.in(["US"]) == .membership(.init(["US"], isMember: true)))
        #expect(Predicate.notIn(["US"]) == .membership(.init(["US"], isMember: false)))
        #expect(Predicate.startsWith("a") == .string(.init(.startsWith, "a")))
        #expect(Predicate.endsWith("a") == .string(.init(.endsWith, "a")))
        #expect(Predicate.contains("a") == .string(.init(.contains, "a")))
        #expect(Predicate.exists == .presence(.init(isPresent: true)))
        #expect(Predicate.notExists == .presence(.init(isPresent: false)))
    }
}
