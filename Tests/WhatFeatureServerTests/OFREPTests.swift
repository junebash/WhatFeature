import Foundation
import HTTPTypes
import HummingbirdTesting
import NIOCore
import NIOFoundationCompat
import Testing
import WhatFeatureCore
import WhatFeatureServer
import WhatFeatureStorage

private let token = "wf_eval_test"

/// Project `demo` with environment `dev`, the token above, and three flags. `half` is an experiment.
private func makeStore() async throws -> SQLiteStore {
    let seed = """
    {"projects": [{"key": "demo", "environments": [{"key": "dev", "evaluationTokens": ["\(token)"]}], "flags": [
      {"key": "new-onboarding", "type": "boolean", "variants": {"on": true, "off": false}, "configs": {"dev": {
        "enabled": true,
        "rules": [{"conditions": [{"attribute": "country", "operator": "equals", "value": "US"}], "result": {"variant": "on"}}],
        "defaultResult": {"variant": "off"}
      }}},
      {"key": "checkout-v2", "type": "boolean", "variants": {"on": true, "off": false}},
      {"key": "half", "type": "boolean", "variants": {"on": true, "off": false}, "isExperiment": true, "configs": {"dev": {
        "enabled": true,
        "defaultResult": {"rollout": [{"variant": "on", "weight": 5000}, {"variant": "off", "weight": 5000}]}
      }}}
    ]}]}
    """
    let store = try SQLiteStore.inMemory()
    try await store.load(try JSONDecoder().decode(Seed.self, from: Data(seed.utf8)))
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

@Suite struct MetadataTests {
    @Test func experimentsSayTheyAreExperiments() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/half", #"{"context": {"targetingKey": "u1"}}"#)
            #expect(reply.status == .ok)
            #expect(reply.json?["metadata"] == ["experiment": true])
        }
    }

    /// Errors about a real flag carry its metadata too, as OFREP allows.
    @Test func errorsKeepTheMetadata() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/half", #"{"context": {}}"#)
            #expect(reply.json?["errorCode"] == "TARGETING_KEY_MISSING")
            #expect(reply.json?["metadata"] == ["experiment": true])
        }
    }

    @Test func otherFlagsHaveNoMetadata() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags/new-onboarding", #"{"context": {}}"#)
            #expect(reply.json?["metadata"] == nil)
            let missing = try await post(client, "/ofrep/v1/evaluate/flags/nope", #"{"context": {}}"#)
            #expect(missing.json?["metadata"] == nil)
        }
    }

    @Test func bulkResultsCarryMetadata() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            let reply = try await post(client, "/ofrep/v1/evaluate/flags", #"{"context": {"targetingKey": "u1"}}"#)
            guard case .array(let flags) = reply.json?["flags"] else { Issue.record("Expected {\"flags\": [...]}"); return }
            let metadata = flags.map { $0["metadata"] }
            #expect(metadata == [nil, ["experiment": true], nil])
        }
    }
}

extension MetadataTests {
    /// Marking a flag as an experiment changes the ETag, so cached clients pick up the new metadata.
    @Test func markingAnExperimentChangesTheETag() async throws {
        let store = try await makeStore()
        try await buildApplication(store: store).test(.router) { client in
            let body = #"{"context": {"targetingKey": "u1"}}"#
            let first = try await post(client, "/ofrep/v1/evaluate/flags", body)
            let etag = try #require(first.headers[.eTag])

            let project = try #require(try await store.project(key: "demo"))
            _ = try await store.updateFlag(key: "checkout-v2", in: project.id, changes: .init(isExperiment: true), by: .system("test"))

            let second = try await post(client, "/ofrep/v1/evaluate/flags", body, headers: [.authorization: "Bearer \(token)", .ifNoneMatch: etag])
            #expect(second.status == .ok)
            guard case .array(let flags) = second.json?["flags"] else { Issue.record("Expected {\"flags\": [...]}"); return }
            #expect(flags.first?["metadata"] == ["experiment": true])
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
            let project = try #require(try await store.project(key: "demo"))
            let dev = try #require(try await store.environment(key: "dev", in: project.id))
            try await store.setConfig(FlagConfig(enabled: true, defaultResult: .variant("on")), flagKey: "checkout-v2", in: dev.id, by: .system("test"))
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

@Suite struct CORSTests {
    private let origin: HTTPFields = [.origin: "https://whatdo.example"]

    @Test(arguments: ["/ofrep/v1/evaluate/flags", "/ofrep/v1/evaluate/flags/new-onboarding"])
    func preflight(_ path: String) async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            var headers = origin
            headers[.accessControlRequestMethod] = "POST"
            headers[.accessControlRequestHeaders] = "authorization, content-type, if-none-match"
            try await client.execute(uri: path, method: .options, headers: headers) { response in
                #expect(response.status == .noContent)
                #expect(response.headers[.accessControlAllowOrigin] == "*")
                #expect(response.headers[.accessControlAllowMethods] == "POST")
                let allowed = Set((response.headers[.accessControlAllowHeaders] ?? "").lowercased().split(separator: ", "))
                #expect(allowed.isSuperset(of: ["authorization", "content-type", "if-none-match"]))
            }
        }
    }

    @Test func responsesExposeETag() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            var headers = origin
            headers[.authorization] = "Bearer \(token)"
            let reply = try await post(client, "/ofrep/v1/evaluate/flags", #"{"context": {}}"#, headers: headers)
            #expect(reply.status == .ok)
            #expect(reply.headers[.accessControlAllowOrigin] == "*")
            #expect(reply.headers[.accessControlExposeHeaders] == "ETag")

            // A browser has to be able to read a 401 too, to tell a bad token from a network error.
            let unauthorized = try await post(client, "/ofrep/v1/evaluate/flags", #"{"context": {}}"#, headers: origin)
            #expect(unauthorized.status == .unauthorized)
            #expect(unauthorized.headers[.accessControlAllowOrigin] == "*")
        }
    }

    @Test func adminHasNoCORS() async throws {
        let app = buildApplication(store: try await makeStore())
        try await app.test(.router) { client in
            var headers = origin
            headers[.accessControlRequestMethod] = "GET"
            try await client.execute(uri: "/admin/v1/me", method: .options, headers: headers) { response in
                #expect(response.headers[.accessControlAllowOrigin] == nil)
            }
        }
    }
}
