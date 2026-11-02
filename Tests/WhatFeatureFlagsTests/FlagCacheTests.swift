import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import WhatFeatureCore
import WhatFeatureFlags

// The client and its cache with a fake network and an in-memory disk: no server, no files.
// (Tests/WhatFeatureIntegrationTests/FlagClientTests reads a real server.)

/// Answers requests with scripted replies, and fails like a dropped connection when it runs out.
private final class FakeServer: Sendable {
    struct Reply: Sendable {
        var status: Int
        var body = ""
        var etag: String?
    }

    private struct State {
        var replies: [Reply] = []
        var requests: [URLRequest] = []
    }

    private let state = Mutex(State())

    func reply(_ reply: Reply) {
        state.withLock { $0.replies.append(reply) }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let reply: Reply? = state.withLock { state in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else { throw URLError(.notConnectedToInternet) }
        let headers = reply.etag.map { ["ETag": $0] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: headers)!
        return (Data(reply.body.utf8), response)
    }
}

/// A disk that lives only as long as the test.
private final class MemoryDisk: Sendable {
    let files = Mutex<[String: Data]>([:])

    var storage: FlagCache.Storage {
        FlagCache.Storage(
            read: { name in self.files.withLock { $0[name] } },
            write: { name, data in self.files.withLock { $0[name] = data } },
            remove: { name in _ = self.files.withLock { $0.removeValue(forKey: name) } }
        )
    }
}

/// A bulk response with one string flag.
private func greeting(_ value: String, etag: String) -> FakeServer.Reply {
    FakeServer.Reply(
        status: 200,
        body: #"{"flags": [{"key": "greeting", "value": "\#(value)", "variant": "\#(value)", "reason": "STATIC"}]}"#,
        etag: etag
    )
}

private struct Setup {
    let server = FakeServer()
    let disk = MemoryDisk()

    /// A new client each time, like a new launch of the app. They share the server and the disk.
    func client(token: String = "wf_eval_dev", maxContexts: Int = 5) -> FlagClient {
        let server = server
        return FlagClient(
            baseURL: URL(string: "https://flags.example.com")!,
            token: token,
            cache: FlagCache(storage: disk.storage, maxContexts: maxContexts)
        ) { try server.send($0) }
    }
}

private let june = EvaluationContext(targetingKey: "june", attributes: ["country": "US"])

@Suite struct FlagCacheTests {
    @Test func theLastFlagsAreThereAtLaunchAndOffline() async throws {
        let setup = Setup()
        #expect(setup.client().cachedFlags(for: june) == nil)

        setup.server.reply(greeting("Hi", etag: #""v1""#))
        let fetched = try await setup.client().fetch(context: june)
        #expect(fetched.string("greeting", default: "") == "Hi")

        // The next launch, offline: the saved flags, and a failed fetch leaves them alone.
        let relaunched = setup.client()
        #expect(relaunched.cachedFlags(for: june) == fetched)
        await #expect(throws: URLError.self) { try await relaunched.fetch(context: june) }
        #expect(relaunched.cachedFlags(for: june) == fetched)

        // Another environment has entries of its own.
        #expect(setup.client(token: "wf_eval_prod").cachedFlags(for: june) == nil)

        // Same user, changed attributes: still the best guess, but the ETag can't be trusted.
        let moved = setup.client().cachedFlags(for: EvaluationContext(targetingKey: "june", attributes: ["country": "DE"]))
        #expect(moved?.string("greeting", default: "") == "Hi")
        #expect(moved?.etag == nil)
    }

    @Test func theCachedETagMakesTheFirstFetchCheap() async throws {
        let setup = Setup()
        setup.server.reply(greeting("Hi", etag: #""v1""#))
        _ = try await setup.client().fetch(context: june)

        setup.server.reply(FakeServer.Reply(status: 304))
        let again = try await setup.client().fetch(context: june)
        #expect(setup.server.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, #""v1""#])
        #expect(again.string("greeting", default: "") == "Hi")
    }

    /// The limit drops whichever user was written longest ago, not whichever was first written.
    @Test func keepsTheMostRecentlyWrittenUsers() async throws {
        let setup = Setup()
        let users = ["a", "b", "a", "c"].map { EvaluationContext(targetingKey: $0) }
        for (index, user) in users.enumerated() {
            setup.server.reply(greeting("Hi", etag: "\"\(index)\""))
            _ = try await setup.client(maxContexts: 2).fetch(context: user)
        }
        let client = setup.client(maxContexts: 2)
        #expect(client.cachedFlags(for: EvaluationContext(targetingKey: "a")) != nil)
        #expect(client.cachedFlags(for: EvaluationContext(targetingKey: "b")) == nil)
        #expect(client.cachedFlags(for: EvaluationContext(targetingKey: "c")) != nil)
        #expect(setup.disk.files.withLock { $0.count } == 3, "two entries and the index")
    }
}
