import Foundation
import HTTPTypes
import HummingbirdTesting
import NIOCore
import NIOFoundationCompat
import Synchronization
import Testing
import WhatFeatureCore
@testable import WhatFeatureServer
import WhatFeatureStorage

/// A clock that only moves when told to.
private final class FakeClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { instant.withLock { $0 } }

    func advance(by duration: Duration) {
        instant.withLock { $0 += duration }
    }
}

@Suite struct RateLimiterTests {
    @Test func allowsAFullMinuteAtOnceThenRefills() {
        let clock = FakeClock()
        // 60 a minute: a bucket of 60, refilling one per second.
        let limiter = RateLimiter(limit: RateLimit(requestsPerMinute: 60), now: { clock.now })
        for _ in 0..<60 {
            #expect(limiter.take("a") == nil)
        }
        #expect(limiter.take("a") == .seconds(1))

        clock.advance(by: .milliseconds(250))
        #expect(limiter.take("a") == .milliseconds(750))

        clock.advance(by: .milliseconds(750))
        #expect(limiter.take("a") == nil)
        #expect(limiter.take("a") != nil)
    }

    @Test func refillStopsAtTheLimit() {
        let clock = FakeClock()
        let limiter = RateLimiter(limit: RateLimit(requestsPerMinute: 2), now: { clock.now })
        clock.advance(by: .seconds(3_600))
        #expect(limiter.take("a") == nil)
        #expect(limiter.take("a") == nil)
        #expect(limiter.take("a") == .seconds(30))
    }

    @Test func eachKeyHasItsOwnBucket() {
        let limiter = RateLimiter(limit: RateLimit(requestsPerMinute: 1))
        #expect(limiter.take("a") == nil)
        #expect(limiter.take("a") != nil)
        #expect(limiter.take("b") == nil)
    }

    @Test func wholeSecondsRoundUpAndAreAtLeastOne() {
        #expect(Duration.milliseconds(1).wholeSecondsRoundedUp == 1)
        #expect(Duration.milliseconds(1_001).wholeSecondsRoundedUp == 2)
        #expect(Duration.seconds(30).wholeSecondsRoundedUp == 30)
    }
}

@Suite struct RateLimitEndpointTests {
    @Test func adminTokenGets429WithSeconds() async throws {
        let store = try SQLiteStore.inMemory()
        let secret = try await store.createAdminToken(name: "test", by: .system("test")).secret

        try await buildApplication(store: store, adminRateLimit: RateLimit(requestsPerMinute: 2)).test(.router) { client in
            func me() async throws -> (HTTPResponse.Status, HTTPFields, JSONValue?) {
                try await client.execute(uri: "/admin/v1/me", method: .get, headers: [.authorization: "Bearer \(secret)"]) { response in
                    let json = try? JSONDecoder().decode(JSONValue.self, from: Data(buffer: response.body))
                    return (response.status, response.headers, json)
                }
            }

            #expect(try await me().0 == .ok)
            #expect(try await me().0 == .ok)
            let (status, headers, json) = try await me()
            #expect(status == .tooManyRequests)
            #expect(headers[.retryAfter] == "30")
            #expect(json == ["error": "Too many requests. Try again in 30 seconds."])
        }
    }

    /// Evaluation tokens are public and shared by every install, so the server never limits them.
    @Test func evaluationTokensAreNeverLimited() async throws {
        let store = try SQLiteStore.inMemory()
        let seed = #"{"projects": [{"key": "demo", "environments": [{"key": "dev", "evaluationTokens": ["wf_eval_one"]}], "flags": []}]}"#
        try await store.load(try JSONDecoder().decode(Seed.self, from: Data(seed.utf8)))
        try await buildApplication(store: store, adminRateLimit: RateLimit(requestsPerMinute: 1)).test(.router) { client in
            for _ in 0..<5 {
                try await client.execute(
                    uri: "/ofrep/v1/evaluate/flags", method: .post,
                    headers: [.authorization: "Bearer wf_eval_one"], body: ByteBuffer(string: #"{"context": {}}"#)
                ) { response in
                    #expect(response.status == .ok)
                }
            }
        }
    }

    @Test func offMeansNoLimit() async throws {
        let store = try SQLiteStore.inMemory()
        let secret = try await store.createAdminToken(name: "test", by: .system("test")).secret
        try await buildApplication(store: store, adminRateLimit: nil).test(.router) { client in
            for _ in 0..<5 {
                try await client.execute(uri: "/admin/v1/me", method: .get, headers: [.authorization: "Bearer \(secret)"]) { response in
                    #expect(response.status == .ok)
                }
            }
        }
    }
}
