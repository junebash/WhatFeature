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

        (Condition("age", .lt(30)), false),
        (Condition("age", .lte(30)), true),
        (Condition("age", .gt(18)), true),
        (Condition("age", .gte(31)), false),

        (Condition("appVersion", .semverEq(SemanticVersion(major: 2, minor: 1))), true),
        (Condition("appVersion", .semverLt(SemanticVersion(major: 10))), true),
        (Condition("appVersion", .semverLte(SemanticVersion(major: 2))), false),
        (Condition("appVersion", .semverGt(SemanticVersion(major: 2))), true),
        (Condition("appVersion", .semverGte(SemanticVersion(major: 2, minor: 2))), false),

        (Condition("country", .exists), true),
        (Condition("country", .notExists), false),
    ])
    func matches(_ condition: Condition, _ expected: Bool) {
        #expect(condition.matches(context) == expected)
    }

    @Test(arguments: [
        Predicate.equals("US"), .notEquals("US"), .in(["US"]), .notIn(["US"]),
        .startsWith("U"), .endsWith("S"), .contains("U"),
        .lt(1), .lte(1), .gt(1), .gte(1),
        .semverEq(SemanticVersion(major: 1)), .semverLt(SemanticVersion(major: 1)),
        .semverLte(SemanticVersion(major: 1)), .semverGt(SemanticVersion(major: 1)),
        .semverGte(SemanticVersion(major: 1)),
        .exists,
    ])
    func missingAttributeNeverMatches(_ predicate: Predicate) {
        #expect(!Condition("missing", predicate).matches(context))
    }

    @Test func missingAttributeMatchesNotExists() {
        #expect(Condition("missing", .notExists).matches(context))
    }

    @Test(arguments: [
        Condition("age", .startsWith("3")),
        Condition("country", .lt(5)),
        Condition("age", .semverGt(SemanticVersion(major: 1))),
        Condition("email", .semverGt(SemanticVersion(major: 1))),
    ])
    func wrongTypeDoesNotMatch(_ condition: Condition) {
        #expect(!condition.matches(context))
    }

    @Test func decodesFromJSON() throws {
        let condition = try decode(Condition.self, from: #"{"attribute": "appVersion", "operator": "semverGte", "value": "2.1"}"#)
        #expect(condition == Condition("appVersion", .semverGte(SemanticVersion(major: 2, minor: 1))))

        let exists = try decode(Condition.self, from: #"{"attribute": "beta", "operator": "exists"}"#)
        #expect(exists == Condition("beta", .exists))
    }

    @Test(arguments: [
        #"{"attribute": "a", "operator": "matches", "value": ".*"}"#,
        #"{"attribute": "a", "operator": "lt", "value": "five"}"#,
        #"{"attribute": "a", "operator": "semverGt", "value": "not-a-version"}"#,
        #"{"attribute": "a", "operator": "in", "value": "US"}"#,
        #"{"attribute": "a", "operator": "equals"}"#,
    ])
    func rejectsBadJSON(_ json: String) {
        #expect(throws: DecodingError.self) {
            try decode(Condition.self, from: json)
        }
    }

    @Test(arguments: [
        Condition("a", .equals(["nested": [1, 2]])), Condition("a", .notIn(["x", 3])),
        Condition("a", .contains("x")), Condition("a", .gte(1.5)),
        Condition("a", .semverLt(SemanticVersion(major: 1, prerelease: ["rc", "1"]))),
        Condition("a", .notExists),
    ])
    func roundTrips(_ condition: Condition) throws {
        #expect(try roundTrip(condition) == condition)
    }
}
