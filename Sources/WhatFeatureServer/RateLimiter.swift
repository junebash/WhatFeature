import Synchronization

/// How many requests one admin token may make: up to `requestsPerMinute` at once, refilling at
/// `requestsPerMinute / 60` per second. This is a token bucket, with the bucket holding one minute's worth.
///
/// Only admin tokens are limited. Evaluation tokens are public and shared by every install of an app, so a
/// per-token limit would let one device (or anyone who pulls the token out of the app) get every install a
/// `429`. Those are for a proxy to limit by client IP. See "Rate limiting" in DESIGN.md.
public struct RateLimit: Sendable, Hashable {
    public var requestsPerMinute: Int

    public init(requestsPerMinute: Int) {
        precondition(requestsPerMinute > 0, "Use nil for no limit")
        self.requestsPerMinute = requestsPerMinute
    }

    public static let adminDefault = RateLimit(requestsPerMinute: 600)
}

/// One bucket per key, held in memory. That works because there's a single server instance.
///
/// Keys are token hashes, and the middleware only asks after the token checks out, so there is at most
/// one bucket per real token. Made-up tokens never get a bucket.
final class RateLimiter: Sendable {
    private struct Bucket {
        var available: Double
        var updatedAt: ContinuousClock.Instant
    }

    let limit: RateLimit
    private let now: @Sendable () -> ContinuousClock.Instant
    private let buckets = Mutex<[String: Bucket]>([:])

    init(limit: RateLimit, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.limit = limit
        self.now = now
    }

    /// Takes one request from `key`'s bucket. Returns `nil` if the request may go ahead, or else how long
    /// until the next one would be allowed.
    func take(_ key: String) -> Duration? {
        let capacity = Double(limit.requestsPerMinute)
        let perSecond = capacity / 60
        let now = now()
        return buckets.withLock { buckets in
            var bucket = buckets[key] ?? Bucket(available: capacity, updatedAt: now)
            let elapsed = (now - bucket.updatedAt).seconds
            bucket.available = min(capacity, bucket.available + elapsed * perSecond)
            bucket.updatedAt = now
            defer { buckets[key] = bucket }
            if bucket.available >= 1 {
                bucket.available -= 1
                return nil
            }
            return .seconds((1 - bucket.available) / perSecond)
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Whole seconds, rounded up, and at least 1. For `Retry-After`.
    var wholeSecondsRoundedUp: Int {
        max(1, Int(seconds.rounded(.up)))
    }
}
