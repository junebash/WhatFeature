import Foundation
import HTTPTypes
import HummingbirdTesting
import NIOCore
import NIOFoundationCompat
import Testing
import WhatFeatureCore
import WhatFeatureServer

private let token = "wf_eval_test"
private let dev = EnvironmentID("dev")

private func booleanFlag(_ key: String) -> Flag {
    Flag(key: key, type: .boolean, variants: ["on": true, "off": false], createdBy: "test", createdAt: Date())
}

private func makeStore() async throws -> InMemoryStore {
    let store = InMemoryStore()
    await store.addEvaluationToken(token, for: dev)
    try await store.put(
        booleanFlag("new-onboarding"),
        config: FlagConfig(
            enabled: true,
            rules: [Rule(conditions: [Condition("country", .equals("US"))], result: .variant("on"))],
            defaultResult: .variant("off")
        ),
        in: dev
    )
    try await store.put(booleanFlag("checkout-v2"), config: FlagConfig(enabled: false, defaultResult: .variant("off")), in: dev)
    try await store.put(booleanFlag("half"), config: FlagConfig(enabled: true, defaultResult: .rollout(["on": 5_000, "off": 5_000])), in: dev)
    return store
}

private struct Reply {
    var status: HTTPResponse.Status
    var headers: HTTPFields
    var json: JSONValue?
}

private func post(
    _ client: some TestClientProtocol,
    _ path: String,
    _ body: String,
    headers: HTTPFields = [.authorization: "Bearer \(token)"]
) async throws -> Reply {
    try await client.execute(uri: path, method: .post, headers: headers, body: ByteBuffer(string: body)) { response in
        let json = response.body.readableBytes == 0
            ? nil
            : try JSONDecoder().decode(JSONValue.self, from: Data(buffer: response.body))
        return Reply(status: response.status, headers: response.headers, json: json)
    }
}

@Suite struct SingleFlagTests {
    @Test func targetingMatch() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/new-onboarding", #"{"context": {"targetingKey": "u1", "country": "US"}}"#)
            #expect(reply.status == .ok)
            #expect(reply.json == ["key": "new-onboarding", "value": true, "variant": "on", "reason": "TARGETING_MATCH"])
        }
    }

    @Test func noRuleMatchedIsDefault() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/new-onboarding", #"{"context": {"country": "DE"}}"#)
            #expect(reply.json == ["key": "new-onboarding", "value": false, "variant": "off", "reason": "DEFAULT"])
        }
    }

    /// OFREP's "codeDefaultFlag": a success with no `value`, so the app uses its own default.
    @Test func disabledHasNoValue() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/checkout-v2", #"{"context": {}}"#)
            #expect(reply.status == .ok)
            #expect(reply.json == ["key": "checkout-v2", "reason": "DISABLED"])
        }
    }

    @Test func unknownFlagIs404() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/nope", #"{"context": {}}"#)
            #expect(reply.status == .notFound)
            guard case .object(let body) = reply.json else { Issue.record("Expected a JSON object"); return }
            #expect(body["key"] == "nope")
            #expect(body["errorCode"] == "FLAG_NOT_FOUND")
        }
    }

    @Test func rolloutWithoutTargetingKeyIs400() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/half", #"{"context": {}}"#)
            #expect(reply.status == .badRequest)
            guard case .object(let body) = reply.json else { Issue.record("Expected a JSON object"); return }
            #expect(body["errorCode"] == "TARGETING_KEY_MISSING")
        }
    }

    @Test(arguments: [
        (#"not json"#, "PARSE_ERROR"),
        (#"{"context": {"targetingKey": 42}}"#, "INVALID_CONTEXT"),
        (#"{"nothing": true}"#, "INVALID_CONTEXT"),
    ])
    func badRequestBody(_ body: String, _ errorCode: String) async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/new-onboarding", body)
            #expect(reply.status == .badRequest)
            guard case .object(let json) = reply.json else { Issue.record("Expected a JSON object"); return }
            #expect(json["key"] == "new-onboarding")
            #expect(json["errorCode"] == .string(errorCode))
        }
    }
}

@Suite struct AuthTests {
    @Test(arguments: [
        HTTPFields(),
        [.authorization: "Bearer wrong"],
        [.authorization: token],  // missing the "Bearer" scheme
    ])
    func rejects(_ headers: HTTPFields) async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/new-onboarding", #"{"context": {}}"#, headers: headers)
            #expect(reply.status == .unauthorized)
        }
    }

    @Test(arguments: [
        [.authorization: "bearer \(token)"],
        [HTTPField.Name("X-API-Key")!: token],
    ] as [HTTPFields])
    func accepts(_ headers: HTTPFields) async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/new-onboarding", #"{"context": {}}"#, headers: headers)
            #expect(reply.status == .ok)
        }
    }

    @Test func healthNeedsNoToken() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok")
            }
        }
    }
}

@Suite struct BulkTests {
    @Test func evaluatesEveryFlagSortedByKey() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags", #"{"context": {"targetingKey": "u1", "country": "US"}}"#)
            #expect(reply.status == .ok)
            #expect(reply.headers[.eTag] != nil)
            guard case .object(let body) = reply.json, case .array(let flags) = body["flags"] else {
                Issue.record("Expected {\"flags\": [...]}")
                return
            }
            let keys = flags.compactMap { flag -> JSONValue? in
                guard case .object(let object) = flag else { return nil }
                return object["key"]
            }
            #expect(keys == ["checkout-v2", "half", "new-onboarding"])
            #expect(flags.first == ["key": "checkout-v2", "reason": "DISABLED"])
        }
    }

    @Test func etagGivesNotModifiedUntilSomethingChanges() async throws {
        let store = try await makeStore()
        let app = buildApplication(store: store)
        try await app.test(.router) { client in
            let body = #"{"context": {"targetingKey": "u1"}}"#
            let first = try await post(client, "/ofrep/v1/evaluate/flags", body)
            let etag = try #require(first.headers[.eTag])

            func withETag(_ etag: String) -> HTTPFields {
                [.authorization: "Bearer \(token)", .ifNoneMatch: etag]
            }

            let unchanged = try await post(client, "/ofrep/v1/evaluate/flags", body, headers: withETag(etag))
            #expect(unchanged.status == .notModified)
            #expect(unchanged.json == nil)

            // A different context must not reuse the old result.
            let otherUser = try await post(client, "/ofrep/v1/evaluate/flags", #"{"context": {"targetingKey": "u2"}}"#, headers: withETag(etag))
            #expect(otherUser.status == .ok)

            // Neither may a changed flag.
            try await store.put(booleanFlag("brand-new"), config: FlagConfig(enabled: true, defaultResult: .variant("on")), in: dev)
            let changed = try await post(client, "/ofrep/v1/evaluate/flags", body, headers: withETag(etag))
            #expect(changed.status == .ok)
            #expect(changed.headers[.eTag] != etag)
        }
    }

    @Test(arguments: ["*", "W/\"other\", \"other\""])
    func ifNoneMatchForms(_ prefix: String) async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let body = #"{"context": {}}"#
            let etag = try #require(try await post(client, "/ofrep/v1/evaluate/flags", body).headers[.eTag])
            let header = prefix == "*" ? "*" : "\(prefix), W/\(etag)"
            let reply = try await post(client, "/ofrep/v1/evaluate/flags", body, headers: [.authorization: "Bearer \(token)", .ifNoneMatch: header])
            #expect(reply.status == .notModified)
        }
    }

    @Test func badBodyHasNoKey() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags", "nope")
            #expect(reply.status == .badRequest)
            guard case .object(let body) = reply.json else { Issue.record("Expected a JSON object"); return }
            #expect(body["key"] == nil)
            #expect(body["errorCode"] == "PARSE_ERROR")
        }
    }
}

@Suite struct SeedTests {
    @Test func exampleSeedLoads() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "examples/seed.json")
        let store = InMemoryStore()
        try await store.load(try Seed.read(from: url))
        #expect(await store.snapshot(for: dev).entries.count == 3)
        #expect(await store.environment(forTokenHash: TokenHash.of("wf_eval_dev_local_only")) == dev)
    }

    @Test func reportsInvalidFlags() async throws {
        let json = """
        {"environments": [{"id": "dev", "evaluationTokens": [], "flags": [
          {"key": "bad", "type": "boolean", "variants": {"on": "yes"}, "config": {"enabled": true, "defaultResult": {"variant": "maybe"}}}
        ]}]}
        """
        let seed = try JSONDecoder().decode(Seed.self, from: Data(json.utf8))
        let error = try await #require(throws: SeedError.self) { try await InMemoryStore().load(seed) }
        #expect(error.issues == ["dev/bad: Variant 'on' doesn't match the flag type 'boolean'"])
    }
}
