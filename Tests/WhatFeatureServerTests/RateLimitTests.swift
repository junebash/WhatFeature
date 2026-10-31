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

    @Test func retryAfterIsAnISO8601DateRoundedUp() {
        let now = Date(timeIntervalSince1970: 1_707_307_199.5) // 2024-02-07T11:59:59.5Z
        #expect(EvaluationTokenMiddleware.retryAfter(.milliseconds(100), from: now) == "2024-02-07T12:00:00Z")
        #expect(EvaluationTokenMiddleware.retryAfter(.seconds(30), from: now) == "2024-02-07T12:00:30Z")
    }

    @Test func wholeSecondsRoundUpAndAreAtLeastOne() {
        #expect(Duration.milliseconds(1).wholeSecondsRoundedUp == 1)
        #expect(Duration.milliseconds(1_001).wholeSecondsRoundedUp == 2)
        #expect(Duration.seconds(30).wholeSecondsRoundedUp == 30)
    }
}

@Suite struct RateLimitEndpointTests {
    private static let limits = RateLimits(evaluation: RateLimit(requestsPerMinute: 2), admin: RateLimit(requestsPerMinute: 2))

    @Test func evaluationTokenGets429WithADate() async throws {
        let store = try SQLiteStore.inMemory()
        let seed = #"{"projects": [{"key": "demo", "environments": [{"key": "dev", "evaluationTokens": ["wf_eval_one", "wf_eval_two"]}], "flags": []}]}"#
        try await store.load(try JSONDecoder().decode(Seed.self, from: Data(seed.utf8)))

        try await buildApplication(store: store, rateLimits: Self.limits).test(.router) { client in
            func evaluate(_ token: String) async throws -> (HTTPResponse.Status, HTTPFields) {
                try await client.execute(
                    uri: "/ofrep/v1/evaluate/flags", method: .post,
                    headers: [.authorization: "Bearer \(token)"], body: ByteBuffer(string: #"{"context": {}}"#)
                ) { ($0.status, $0.headers) }
            }

            #expect(try await evaluate("wf_eval_one").0 == .ok)
            #expect(try await evaluate("wf_eval_one").0 == .ok)
            let (status, headers) = try await evaluate("wf_eval_one")
            #expect(status == .tooManyRequests)
            let retryAfter = try #require(headers[.retryAfter])
            let date = try Date(retryAfter, strategy: .iso8601)
            #expect(date > .now.addingTimeInterval(20))
            #expect(date < .now.addingTimeInterval(40))

            // Another token has its own limit.
            #expect(try await evaluate("wf_eval_two").0 == .ok)
            // A made-up token is still just unauthorized.
            #expect(try await evaluate("wf_eval_nope").0 == .unauthorized)
        }
    }

    @Test func adminTokenGets429WithSeconds() async throws {
        let store = try SQLiteStore.inMemory()
        let secret = try await store.createAdminToken(name: "test", by: .system("test")).secret

        try await buildApplication(store: store, rateLimits: Self.limits).test(.router) { client in
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

    @Test func offMeansNoLimit() async throws {
        let store = try SQLiteStore.inMemory()
        let secret = try await store.createAdminToken(name: "test", by: .system("test")).secret
        try await buildApplication(store: store, rateLimits: .off).test(.router) { client in
            for _ in 0..<5 {
                try await client.execute(uri: "/admin/v1/me", method: .get, headers: [.authorization: "Bearer \(secret)"]) { response in
                    #expect(response.status == .ok)
                }
            }
        }
    }
}
