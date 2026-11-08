import Foundation
import HTTPTypes
import HummingbirdTesting
import NIOCore
import Testing
import WhatFeatureServer
import WhatFeatureStorage

@Suite struct WebUITests {
    /// A folder shaped like `ui/dist`: an index and a hashed asset.
    private static func makeBuild() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "whatfeature-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "assets"), withIntermediateDirectories: true)
        try Data("<!doctype html><title>WhatFeature</title>".utf8).write(to: directory.appending(path: "index.html"))
        try Data("console.log(1)".utf8).write(to: directory.appending(path: "assets/index-abc123.js"))
        return directory.path
    }

    @Test func servesTheBuildAtUIWithAStrictPolicy() async throws {
        let store = try SQLiteStore.inMemory()
        try await buildApplication(store: store, uiDirectory: try Self.makeBuild()).test(.router) { client in
            try await client.execute(uri: "/ui/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("<title>WhatFeature</title>"))
                #expect(response.headers[.contentSecurityPolicy]?.contains("default-src 'self'") == true)
                #expect(response.headers[.contentSecurityPolicy]?.contains("frame-ancestors 'none'") == true)
                #expect(response.headers[.cacheControl] == "no-cache")
            }
            try await client.execute(uri: "/ui/assets/index-abc123.js", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl]?.contains("immutable") == true)
            }
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.headers[.location] == "/ui/")
            }
            // The API is untouched: still JSON, still needs a token, no page headers.
            try await client.execute(uri: "/admin/v1/projects", method: .get) { response in
                #expect(response.status == .unauthorized)
                #expect(response.headers[.contentSecurityPolicy] == nil)
            }
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(String(buffer: response.body) == "ok")
            }
        }
    }

    @Test func noUIUnlessAFolderIsGiven() async throws {
        let store = try SQLiteStore.inMemory()
        try await buildApplication(store: store).test(.router) { client in
            try await client.execute(uri: "/ui/", method: .get) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
