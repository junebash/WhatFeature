import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HummingbirdTesting
import Testing
import WhatFeatureCore
import WhatFeatureFlags
import WhatFeatureServer
import WhatFeatureStorage

// A real server on a real port, read by `FlagClient`, the client apps use. The server's own OFREP tests pin
// the JSON; these check the client reads it the way an app needs.

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

/// Runs the server on a free port and hands the test a client pointed at it, plus the store for changing flags.
private func withClient(token: String = token, _ test: @Sendable (FlagClient, SQLiteStore) async throws -> Void) async throws {
    let store = try SQLiteStore.inMemory()
    try await store.load(try JSONDecoder().decode(Seed.self, from: Data(seed.utf8)))
    try await buildApplication(store: store).test(.live) { client in
        let port = try #require(client.port)
        // "localhost", not 127.0.0.1: see the note in AdminClientTests.
        let url = try #require(URL(string: "http://localhost:\(port)"))
        try await test(FlagClient(baseURL: url, token: token, session: .shared), store)
    }
}

@Suite struct FlagClientTests {
    @Test func valuesFollowTheRules() async throws {
        try await withClient { client, _ in
            let us = try await client.fetch(context: EvaluationContext(targetingKey: "u1", attributes: ["country": "US", "plan": "pro"]))
            #expect(us.bool("new-onboarding", default: false) == true)
            #expect(us["new-onboarding"]?.reason == .targetingMatch)
            #expect(us["new-onboarding"]?.variant == "on")
            #expect(us.string("greeting", default: "Hey") == "Hi")
            #expect(us.double("discount", default: -1) == 0.25)
            #expect(us.int("discount", default: -1) == -1, "0.25 isn't a whole number")

            let de = try await client.fetch(context: EvaluationContext(targetingKey: "u1", attributes: ["country": "DE"]))
            #expect(de.bool("new-onboarding", default: true) == false)
            #expect(de["new-onboarding"]?.reason == .default)
            // JSON sends 0.0 as 0: it's both a Double and an Int.
            #expect(de.double("discount", default: -1) == 0)
            #expect(de.int("discount", default: -1) == 0)
        }
    }

    /// Disabled, failed, missing or of another type: the app's own default wins, whichever it is.
    @Test func everythingElseGetsTheAppsDefault() async throws {
        try await withClient { client, _ in
            let flags = try await client.fetch(context: EvaluationContext())
            for defaultValue in [true, false] {
                #expect(flags.bool("checkout-v2", default: defaultValue) == defaultValue)
                #expect(flags.bool("paywall-test", default: defaultValue) == defaultValue)
                #expect(flags.bool("nope", default: defaultValue) == defaultValue)
                #expect(flags.bool("greeting", default: defaultValue) == defaultValue)
            }
            #expect(flags["checkout-v2"]?.reason == .disabled)
            #expect(flags["paywall-test"]?.errorCode == .targetingKeyMissing, "rollouts need a targeting key")
            #expect(flags.string("new-onboarding", default: "x") == "x")
        }
    }

    @Test func experimentsAreMarked() async throws {
        try await withClient { client, _ in
            let flags = try await client.fetch(context: EvaluationContext(targetingKey: "june"))
            #expect(flags["paywall-test"]?.isExperiment == true)
            #expect(flags["paywall-test"]?.reason == .split)
            #expect(flags["greeting"]?.isExperiment == false)
        }
    }

    @Test func previousIsReusedOnlyWhileNothingChanged() async throws {
        try await withClient { client, store in
            let context = EvaluationContext(targetingKey: "u1", attributes: ["country": "US"])
            let first = try await client.fetch(context: context)
            #expect(first.etag != nil)

            // A 304 hands back `previous` as it is, so a marked copy shows the server said "unchanged".
            var marked = first
            marked.flags.removeAll()
            #expect(try await client.fetch(context: context, previous: marked) == marked)

            // Another context, or a changed flag, gets fresh values.
            let de = try await client.fetch(context: EvaluationContext(targetingKey: "u1", attributes: ["country": "DE"]), previous: marked)
            #expect(de.bool("new-onboarding", default: true) == false)

            let project = try #require(try await store.project(key: "demo"))
            let dev = try #require(try await store.environment(key: "dev", in: project.id))
            try await store.setConfig(FlagConfig(enabled: false, defaultResult: .variant("off")), flagKey: "new-onboarding", in: dev.id, by: .system("test"))
            let changed = try await client.fetch(context: context, previous: marked)
            #expect(changed["new-onboarding"]?.reason == .disabled)
            #expect(changed.etag != first.etag)
        }
    }

    @Test func aBadTokenThrows() async throws {
        try await withClient(token: "wf_eval_nope") { client, _ in
            await #expect(throws: FlagClientError.self) {
                try await client.fetch(context: EvaluationContext())
            }
        }
    }

    @Test func survivesBeingSaved() async throws {
        try await withClient { client, _ in
            let flags = try await client.fetch(context: EvaluationContext(targetingKey: "june"))
            let saved = try JSONDecoder().decode(Flags.self, from: try JSONEncoder().encode(flags))
            #expect(saved == flags)
        }
    }
}
