import Foundation
import HTTPTypes
import HummingbirdTesting
import NIOCore
import NIOFoundationCompat
import Testing
import WhatFeatureCore
import WhatFeatureServer
import WhatFeatureStorage

private struct Admin {
    var store: SQLiteStore
    /// Admin token secret.
    var token: String
    var tokenID: TokenID

    static func make() async throws -> Admin {
        let store = try SQLiteStore.inMemory()
        let created = try await store.createAdminToken(name: "test", by: .system("test"))
        return Admin(store: store, token: created.secret, tokenID: created.token.id)
    }

    /// Creates project `demo`, environment `dev`, and boolean flag `beta` through the API.
    func setUp(_ client: some TestClientProtocol) async throws {
        try await expect(client, .post, "/admin/v1/projects", #"{"key": "demo", "name": "Demo"}"#, status: .created)
        try await expect(client, .post, "/admin/v1/projects/demo/environments", #"{"key": "dev"}"#, status: .created)
        try await expect(
            client, .post, "/admin/v1/projects/demo/flags",
            #"{"key": "beta", "type": "boolean", "variants": {"on": true, "off": false}}"#, status: .created
        )
    }

    @discardableResult
    func send(
        _ client: some TestClientProtocol,
        _ method: HTTPRequest.Method,
        _ path: String,
        _ body: String? = nil,
        token: String? = nil
    ) async throws -> (status: HTTPResponse.Status, json: JSONValue?) {
        var headers: HTTPFields = [.authorization: "Bearer \(token ?? self.token)"]
        if body != nil { headers[.contentType] = "application/json" }
        return try await client.execute(uri: path, method: method, headers: headers, body: body.map { ByteBuffer(string: $0) }) { response in
            let json = response.body.readableBytes == 0
                ? nil
                : try JSONDecoder().decode(JSONValue.self, from: Data(buffer: response.body))
            return (response.status, json)
        }
    }

    /// Sends and checks the status, recording the body on failure so it's easy to see why.
    @discardableResult
    func expect(
        _ client: some TestClientProtocol,
        _ method: HTTPRequest.Method,
        _ path: String,
        _ body: String? = nil,
        token: String? = nil,
        status: HTTPResponse.Status,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> JSONValue? {
        let reply = try await send(client, method, path, body, token: token)
        #expect(reply.status == status, "\(method) \(path): \(String(describing: reply.json))", sourceLocation: sourceLocation)
        return reply.json
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { array[index] } else { nil }
    }

    var count: Int? {
        if case .array(let array) = self { array.count } else { nil }
    }
}

@Suite struct AdminAuthTests {
    @Test func needsAToken() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await client.execute(uri: "/admin/v1/projects", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
            try await admin.expect(client, .get, "/admin/v1/projects", token: "wf_admin_nope", status: .unauthorized)
        }
    }

    @Test func evaluationTokensAreForbidden() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            let created = try await admin.expect(
                client, .post, "/admin/v1/tokens",
                #"{"name": "iOS", "kind": "evaluation", "project": "demo", "environment": "dev"}"#, status: .created
            )
            let secret = try #require(created?["secret"]?.stringValue)
            try await admin.expect(client, .get, "/admin/v1/projects", token: secret, status: .forbidden)
        }
    }

    @Test func revokedAdminTokensStopWorking() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.expect(client, .post, "/admin/v1/tokens/\(admin.tokenID)/revoke", status: .ok)
            try await admin.expect(client, .get, "/admin/v1/projects", status: .unauthorized)
        }
    }
}

@Suite struct AdminProjectTests {
    @Test func createListAndConflicts() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            let project = try await admin.expect(client, .post, "/admin/v1/projects", #"{"key": "demo", "name": "Demo"}"#, status: .created)
            #expect(project?["key"] == "demo")
            #expect(project?["id"]?.stringValue != nil, "IDs are plain strings")

            #expect(try await admin.expect(client, .get, "/admin/v1/projects", status: .ok)?.count == 1)
            #expect(try await admin.expect(client, .get, "/admin/v1/projects/demo", status: .ok)?["name"] == "Demo")

            let conflict = try await admin.expect(client, .post, "/admin/v1/projects", #"{"key": "demo"}"#, status: .conflict)
            #expect(conflict?["error"] == "A project with key 'demo' already exists")

            let invalid = try await admin.expect(client, .post, "/admin/v1/projects", #"{"key": "has space"}"#, status: .badRequest)
            #expect(invalid?["issues"]?.count == 1)

            try await admin.expect(client, .get, "/admin/v1/projects/nope", status: .notFound)
            try await admin.expect(client, .get, "/admin/v1/projects/nope/flags", status: .notFound)
        }
    }

    @Test func badBodies() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            let notJSON = try await admin.expect(client, .post, "/admin/v1/projects", "nope", status: .badRequest)
            #expect(notJSON?["error"]?.stringValue?.hasPrefix("Invalid request body") == true)
            let missingKey = try await admin.expect(client, .post, "/admin/v1/projects", #"{"name": "x"}"#, status: .badRequest)
            #expect(missingKey?["error"] == "Invalid request body: Missing 'key'")
        }
    }

    @Test func newEnvironmentShowsUpInFlagConfigs() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            try await admin.expect(client, .post, "/admin/v1/projects/demo/environments", #"{"key": "prod"}"#, status: .created)
            let detail = try await admin.expect(client, .get, "/admin/v1/projects/demo/flags/beta", status: .ok)
            #expect(detail?["configs"]?["prod"]?["enabled"] == false)
            #expect(detail?["configs"]?["dev"]?["enabled"] == false)
        }
    }
}

@Suite struct AdminFlagTests {
    /// The whole point: create a flag over the admin API, turn it on, and see it through OFREP.
    @Test func endToEnd() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            let saved = try await admin.expect(client, .put, "/admin/v1/projects/demo/environments/dev/flags/beta", """
            {"enabled": true,
             "rules": [{"conditions": [{"attribute": "country", "operator": "equals", "value": "US"}], "result": {"variant": "on"}}],
             "defaultResult": {"variant": "off"}}
            """, status: .ok)
            #expect(saved?["version"] == 2)

            let created = try await admin.expect(
                client, .post, "/admin/v1/tokens",
                #"{"name": "iOS", "kind": "evaluation", "project": "demo", "environment": "dev"}"#, status: .created
            )
            let secret = try #require(created?["secret"]?.stringValue)
            let evaluation = try await admin.expect(
                client, .post, "/ofrep/v1/evaluate/flags/beta", #"{"context": {"country": "US"}}"#, token: secret, status: .ok
            )
            #expect(evaluation == ["key": "beta", "value": true, "variant": "on", "reason": "TARGETING_MATCH"])

            // Revoking the token through the API cuts off evaluation.
            let tokenID = try #require(created?["token"]?["id"]?.stringValue)
            try await admin.expect(client, .post, "/admin/v1/tokens/\(tokenID)/revoke", status: .ok)
            try await admin.expect(client, .post, "/ofrep/v1/evaluate/flags/beta", #"{"context": {}}"#, token: secret, status: .unauthorized)
        }
    }

    @Test func invalidConfigListsIssues() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            let reply = try await admin.expect(
                client, .put, "/admin/v1/projects/demo/environments/dev/flags/beta",
                #"{"enabled": true, "defaultResult": {"rollout": [{"variant": "on", "weight": 10}]}}"#, status: .badRequest
            )
            #expect(reply?["issues"] == ["Default: weights add up to 10, not 10000"])

            let badOperator = try await admin.expect(
                client, .put, "/admin/v1/projects/demo/environments/dev/flags/beta",
                #"{"enabled": true, "rules": [{"conditions": [{"attribute": "a", "operator": "matches", "value": "x"}], "result": {"variant": "on"}}], "defaultResult": {"variant": "off"}}"#,
                status: .badRequest
            )
            #expect(badOperator?["error"]?.stringValue?.contains("matches") == true)
        }
    }

    @Test func cantRemoveAVariantInUse() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            let reply = try await admin.expect(
                client, .patch, "/admin/v1/projects/demo/flags/beta", #"{"variants": {"on": true}}"#, status: .badRequest
            )
            #expect(reply?["issues"] == ["Environment 'dev': Default: unknown variant 'off'"])

            let updated = try await admin.expect(
                client, .patch, "/admin/v1/projects/demo/flags/beta", #"{"description": "Beta features", "isExperiment": true}"#, status: .ok
            )
            #expect(updated?["flag"]?["description"] == "Beta features")
            #expect(updated?["flag"]?["isExperiment"] == true)
        }
    }

    @Test func archiveUnarchiveDelete() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            let archived = try await admin.expect(client, .post, "/admin/v1/projects/demo/flags/beta/archive", status: .ok)
            #expect(archived?["flag"]?["archivedAt"]?.stringValue != nil)
            #expect(try await admin.expect(client, .get, "/admin/v1/projects/demo/flags", status: .ok)?.count == 0)
            #expect(try await admin.expect(client, .get, "/admin/v1/projects/demo/flags?includeArchived=true", status: .ok)?.count == 1)

            try await admin.expect(client, .post, "/admin/v1/projects/demo/flags/beta/unarchive", status: .ok)
            #expect(try await admin.expect(client, .get, "/admin/v1/projects/demo/flags", status: .ok)?.count == 1)

            try await admin.expect(client, .delete, "/admin/v1/projects/demo/flags/beta", status: .noContent)
            try await admin.expect(client, .get, "/admin/v1/projects/demo/flags/beta", status: .notFound)
            try await admin.expect(client, .get, "/admin/v1/projects/demo/environments/dev/flags/beta", status: .notFound)
        }
    }

    @Test func listSortingAndFilters() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            try await admin.expect(
                client, .post, "/admin/v1/projects/demo/flags",
                #"{"key": "alpha", "type": "string", "variants": {"a": "A"}}"#, status: .created
            )
            func keys(_ query: String) async throws -> [JSONValue]? {
                guard case .array(let flags) = try await admin.expect(client, .get, "/admin/v1/projects/demo/flags\(query)", status: .ok) else {
                    return nil
                }
                return flags.map { $0["key"] ?? .null }
            }
            #expect(try await keys("") == ["alpha", "beta"])
            #expect(try await keys("?order=desc") == ["beta", "alpha"])
            #expect(try await keys("?sort=createdAt&order=desc") == ["alpha", "beta"])
            #expect(try await keys("?createdBy=token:\(admin.tokenID)")?.count == 2)
            #expect(try await keys("?createdBy=token:someone-else") == [])
            try await admin.expect(client, .get, "/admin/v1/projects/demo/flags?sort=color", status: .badRequest)
        }
    }

    @Test func dryRunExplainsTheResult() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            try await admin.expect(client, .put, "/admin/v1/projects/demo/environments/dev/flags/beta", """
            {"enabled": true,
             "rules": [{"conditions": [{"attribute": "targetingKey", "operator": "in", "value": ["june"]}], "result": {"variant": "on"}}],
             "defaultResult": {"variant": "off"}}
            """, status: .ok)

            let path = "/admin/v1/projects/demo/environments/dev/flags/beta/evaluate"
            let june = try await admin.expect(client, .post, path, #"{"context": {"targetingKey": "june"}}"#, status: .ok)
            #expect(june == ["key": "beta", "value": true, "variant": "on", "reason": "TARGETING_MATCH", "matchedRule": 0, "configVersion": 2])

            let someoneElse = try await admin.expect(client, .post, path, #"{"context": {"targetingKey": "sam"}}"#, status: .ok)
            #expect(someoneElse?["reason"] == "DEFAULT")
            #expect(someoneElse?["matchedRule"] == nil)
        }
    }
}

@Suite struct AdminTokenAndAuditTests {
    @Test func tokenRequestsAreChecked() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            try await admin.expect(client, .post, "/admin/v1/tokens", #"{"name": "x", "kind": "admin", "project": "demo"}"#, status: .badRequest)
            try await admin.expect(client, .post, "/admin/v1/tokens", #"{"name": "x", "kind": "evaluation"}"#, status: .badRequest)
            try await admin.expect(
                client, .post, "/admin/v1/tokens",
                #"{"name": "x", "kind": "evaluation", "project": "demo", "environment": "nope"}"#, status: .notFound
            )
            let created = try await admin.expect(client, .post, "/admin/v1/tokens", #"{"name": "CI", "kind": "admin"}"#, status: .created)
            #expect(created?["secret"]?.stringValue?.hasPrefix("wf_admin_") == true)

            let tokens = try await admin.expect(client, .get, "/admin/v1/tokens", status: .ok)
            #expect(tokens?.count == 2)
            #expect(tokens?[1]?["secret"] == nil, "Listing never shows secrets")
            #expect(tokens?[1]?["hash"] == nil, "or hashes")
        }
    }

    @Test func auditRecordsWhoDidWhat() async throws {
        let admin = try await Admin.make()
        try await buildApplication(store: admin.store).test(.router) { client in
            try await admin.setUp(client)
            try await admin.expect(
                client, .put, "/admin/v1/projects/demo/environments/dev/flags/beta",
                #"{"enabled": true, "defaultResult": {"variant": "on"}}"#, status: .ok
            )

            let entries = try await admin.expect(client, .get, "/admin/v1/audit?project=demo&flag=beta", status: .ok)
            #expect(entries?.count == 2)
            let latest = try #require(entries?[0])
            #expect(latest["action"] == "flagConfig.update")
            #expect(latest["actor"] == .string("token:\(admin.tokenID)"))
            #expect(latest["before"]?["enabled"] == false, "before/after are JSON, not strings")
            #expect(latest["after"]?["enabled"] == true)

            #expect(try await admin.expect(client, .get, "/admin/v1/audit?limit=1", status: .ok)?.count == 1)
            #expect(try await admin.expect(client, .get, "/admin/v1/audit?actor=system:test", status: .ok)?.count == 1)
            #expect(try await admin.expect(client, .get, "/admin/v1/audit?since=2100-01-01T00:00:00Z", status: .ok)?.count == 0)
            try await admin.expect(client, .get, "/admin/v1/audit?since=yesterday", status: .badRequest)
            try await admin.expect(client, .get, "/admin/v1/audit?limit=0", status: .badRequest)
        }
    }
}
