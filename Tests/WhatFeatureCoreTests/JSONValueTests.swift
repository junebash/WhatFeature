import Testing
import WhatFeatureCore

@Suite struct JSONValueTests {
    @Test func decodesEveryKind() throws {
        let value = try decode(JSONValue.self, from: #"{"a": null, "b": true, "c": 1.5, "d": "x", "e": [1, "y"], "f": {"g": false}}"#)
        #expect(value == ["a": nil, "b": true, "c": 1.5, "d": "x", "e": [1, "y"], "f": ["g": false]])
    }

    @Test func keepsBoolsAndNumbersApart() throws {
        #expect(try decode(JSONValue.self, from: "1") == .number(1))
        #expect(try decode(JSONValue.self, from: "0") == .number(0))
        #expect(try decode(JSONValue.self, from: "true") == .bool(true))
    }

    @Test func roundTrips() throws {
        let value: JSONValue = ["list": [1, 2.5, "three", nil], "nested": ["ok": true]]
        #expect(try roundTrip(value) == value)
    }
}

@Suite struct EvaluationContextTests {
    @Test func decodesFlatOFREPObject() throws {
        let context = try decode(EvaluationContext.self, from: #"{"targetingKey": "user-1", "appVersion": "2.0.0"}"#)
        #expect(context.targetingKey == "user-1")
        #expect(context.attributes == ["appVersion": "2.0.0"])
    }

    @Test func rejectsNonStringTargetingKey() {
        #expect(throws: DecodingError.self) {
            try decode(EvaluationContext.self, from: #"{"targetingKey": 42}"#)
        }
    }

    @Test func treatsEmptyTargetingKeyAsMissing() throws {
        #expect(EvaluationContext(targetingKey: "").targetingKey == nil)
        #expect(try decode(EvaluationContext.self, from: #"{"targetingKey": ""}"#).targetingKey == nil)

        var context = EvaluationContext(targetingKey: "user-1")
        context.targetingKey = ""
        #expect(context.targetingKey == nil)
    }

    @Test func treatsNullAttributeAsMissing() {
        let context = EvaluationContext(attributes: ["country": nil])
        #expect(context.value(for: "country") == nil)
    }

    @Test func exposesTargetingKeyAsAttribute() {
        #expect(EvaluationContext(targetingKey: "user-1").value(for: "targetingKey") == "user-1")
    }

    @Test func roundTrips() throws {
        let context = EvaluationContext(targetingKey: "user-1", attributes: ["beta": true])
        #expect(try roundTrip(context) == context)
    }
}
