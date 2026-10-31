import Foundation
import HTTPTypes
import HummingbirdTesting
import OFREP
import OpenFeature
import Testing
import WhatFeatureServer
import WhatFeatureStorage

// A real server on a real port, read by `swift-ofrep`, the OFREP provider a server-side Swift app would use.
// Our other OFREP tests check the JSON against what we think the spec says; these check that a real client
// agrees.

private let token = "wf_eval_live"

private let seed = """
{"projects": [{"key": "demo", "environments": [{"key": "dev", "evaluationTokens": ["\(token)"]}], "flags": [
  {"key": "new-onboarding", "type": "boolean", "variants": {"on": true, "off": false}, "configs": {"dev": {
    "enabled": true,
    "rules": [{"conditions": [{"attribute": "country", "operator": "equals", "value": "US"}], "result": {"variant": "on"}}],
    "defaultResult": {"variant": "off"}
  }}},
  {"key": "greeting", "type": "string", "variants": {"formal": "Hello", "casual": "Hi"}, "configs": {"dev": {
    "enabled": true, "defaultResult": {"variant": "casual"}
  }}},
  {"key": "discount", "type": "number", "variants": {"none": 0, "some": 0.25}, "configs": {"dev": {
    "enabled": true,
    "rules": [{"conditions": [{"attribute": "plan", "operator": "equals", "value": "pro"}], "result": {"variant": "some"}}],
    "defaultResult": {"variant": "none"}
  }}},
  {"key": "checkout-v2", "type": "boolean", "variants": {"on": true, "off": false}},
  {"key": "paywall-test", "type": "boolean", "variants": {"on": true, "off": false}, "isExperiment": true, "configs": {"dev": {
    "enabled": true,
    "defaultResult": {"rollout": [{"variant": "on", "weight": 5000}, {"variant": "off", "weight": 5000}]}
  }}}
]}]}
"""

/// Runs the server on a free port and hands the test a provider pointed at it.
private func withProvider(
    token: String? = token,
    _ test: @Sendable (any OpenFeatureProvider) async throws -> Void
) async throws {
    let store = try SQLiteStore.inMemory()
    try await store.load(try JSONDecoder().decode(Seed.self, from: Data(seed.utf8)))
    try await buildApplication(store: store).test(.live) { client in
        let port = try #require(client.port)
        // "localhost", not 127.0.0.1: see the note in AdminClientTests.
        let url = try #require(URL(string: "http://localhost:\(port)"))
        let headers: HTTPFields = token.map { [.authorization: "Bearer \($0)"] } ?? [:]
        try await test(OFREPProvider(serverURL: url, headerFields: headers))
    }
}

private func context(_ targetingKey: String? = nil, _ fields: [String: OpenFeatureFieldValue] = [:]) -> OpenFeatureEvaluationContext {
    OpenFeatureEvaluationContext(targetingKey: targetingKey, fields: fields)
}

@Suite struct OFREPProviderTests {
    @Test func booleanTargetingMatch() async throws {
        try await withProvider { provider in
            let us = await provider.resolution(of: "new-onboarding", defaultValue: false, context: context("u1", ["country": "US"]))
            #expect(us.value == true)
            #expect(us.variant == "on")
            #expect(us.reason == .targetingMatch)
            #expect(us.error == nil)

            let de = await provider.resolution(of: "new-onboarding", defaultValue: true, context: context("u1", ["country": "DE"]))
            #expect(de.value == false)
            #expect(de.reason == .default)
        }
    }

    @Test func string() async throws {
        try await withProvider { provider in
            let resolution = await provider.resolution(of: "greeting", defaultValue: "Hey", context: context())
            #expect(resolution.value == "Hi")
            #expect(resolution.variant == "casual")
            #expect(resolution.reason == .static)
        }
    }

    @Test func fractionalNumberAsDouble() async throws {
        try await withProvider { provider in
            let resolution = await provider.resolution(of: "discount", defaultValue: -1.0, context: context(nil, ["plan": "pro"]))
            #expect(resolution.value == 0.25)
            #expect(resolution.error == nil)
        }
    }

    /// JSON has one number type, so we send a whole-number value like 0.0 as `0`. A client asking for a
    /// `Double` must still get it. (Upstream swift-ofrep gave TYPE_MISMATCH here; our fork fixes it.)
    @Test func wholeNumberAsDouble() async throws {
        try await withProvider { provider in
            let resolution = await provider.resolution(of: "discount", defaultValue: -1.0, context: context())
            #expect(resolution.value == 0)
            #expect(resolution.error == nil)
        }
    }

    /// OFREP's "code default": the flag is off, so the app's own default wins, and it isn't an error.
    @Test func disabledUsesTheCodeDefault() async throws {
        try await withProvider { provider in
            for defaultValue in [true, false] {
                let resolution = await provider.resolution(of: "checkout-v2", defaultValue: defaultValue, context: context())
                #expect(resolution.value == defaultValue)
                #expect(resolution.reason == .disabled)
                #expect(resolution.error == nil)
            }
        }
    }

    @Test func experimentMetadataReachesTheApp() async throws {
        try await withProvider { provider in
            let experiment = await provider.resolution(of: "paywall-test", defaultValue: false, context: context("june"))
            #expect(experiment.reason == .split)
            #expect(experiment.flagMetadata["experiment"] == .bool(true))

            let other = await provider.resolution(of: "greeting", defaultValue: "Hey", context: context())
            #expect(other.flagMetadata.isEmpty)
        }
    }

    @Test func errors() async throws {
        try await withProvider { provider in
            let missing = await provider.resolution(of: "nope", defaultValue: true, context: context())
            #expect(missing.value == true)
            #expect(missing.error?.code == .flagNotFound)

            let noKey = await provider.resolution(of: "paywall-test", defaultValue: true, context: context())
            #expect(noKey.value == true)
            #expect(noKey.error?.code == .targetingKeyMissing)

            let wrongType = await provider.resolution(of: "greeting", defaultValue: false, context: context())
            #expect(wrongType.value == false)
            #expect(wrongType.error?.code == .typeMismatch)
        }
    }

    /// Without a token the app gets its own defaults. This is what stock `swift-ofrep` would always get.
    @Test func noTokenGetsTheDefault() async throws {
        try await withProvider(token: nil) { provider in
            let resolution = await provider.resolution(of: "new-onboarding", defaultValue: true, context: context("u1", ["country": "US"]))
            #expect(resolution.value == true)
            #expect(resolution.reason == .error)
        }
    }
}
