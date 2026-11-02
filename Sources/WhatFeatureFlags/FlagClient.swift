import Dispatch
public import Foundation
#if canImport(FoundationNetworking)
public import FoundationNetworking
#endif
public import WhatFeatureCore

/// Gets flag values from a WhatFeature server, the way an app does: every flag at once, from OFREP's bulk
/// endpoint. Needs only Foundation, so it works in iOS apps and server-side Swift alike.
///
/// ```swift
/// let client = FlagClient(baseURL: serverURL, token: "wf_eval_…", session: .shared)
/// var flags = try await client.fetch(context: EvaluationContext(targetingKey: userID))
/// if flags.bool("new-onboarding", default: false) { … }
/// flags = try await client.fetch(context: sameContext, previous: flags)  // cheap when nothing changed
/// ```
///
/// With a `FlagCache`, every successful fetch is saved, and `cachedFlags(for:)` gives you the last ones at
/// launch, before the network answers.
public struct FlagClient: Sendable {
    /// e.g. `https://flags.example.com`.
    public var baseURL: URL
    /// An evaluation token (`wf_eval_…`). It picks the project and environment. Treat it as public.
    public var token: String
    public var cache: FlagCache?
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession, cache: FlagCache? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.cache = cache
    }

    /// The flags the cache last saved for this context's targeting key, or `nil` (no cache, nothing saved,
    /// or unreadable). Reads a small file, so it's fine at launch.
    public func cachedFlags(for context: EvaluationContext) -> Flags? {
        try? cache?.load(token: token, context: context)
    }

    /// Every flag for `context`. Pass what you got last time as `previous`: if neither the flags nor the
    /// context changed, the server answers `304` without evaluating anything, and you get `previous` back.
    /// With a cache, `previous` defaults to the cached flags, and new flags are saved.
    public func fetch(context: EvaluationContext, previous: Flags? = nil) async throws -> Flags {
        var previous = previous
        if previous == nil, cache != nil {
            previous = await onFileQueue { cachedFlags(for: context) }
        }

        var request = URLRequest(url: baseURL.appending(path: "ofrep/v1/evaluate/flags"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag = previous?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        request.httpBody = try JSONEncoder().encode(["context": context])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 304, let previous { return previous }
        guard status == 200 else {
            throw FlagClientError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        var flags = try JSONDecoder().decode(Flags.self, from: data)
        flags.etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        if let cache {
            // A cache that can't be written isn't worth failing the fetch for.
            await onFileQueue { [token, flags] in try? cache.save(flags, token: token, context: context) }
        }
        return flags
    }
}

/// File reads and writes block, so they run on a Dispatch queue, not Swift concurrency's shared threads.
private func onFileQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
    }
}

/// The server didn't answer with flags, e.g. `401` for a missing, revoked or archived token.
public struct FlagClientError: Error, Sendable, CustomStringConvertible {
    public var status: Int
    public var body: String

    public var description: String { "WhatFeature answered HTTP \(status): \(body)" }
}

/// Every flag's result for one context. `Codable`, so an app can save it and use it on the next launch
/// before the network answers.
///
/// The getters never fail: a flag that's missing, disabled, failed, or of another type gives you your
/// own default, the same as OFREP's "code default".
public struct Flags: Sendable, Hashable, Codable {
    /// Keyed by flag key. (On the wire, and when saved, it's OFREP's array.)
    public var flags: [String: Flag]
    /// For `FlagClient.fetch(context:previous:)`.
    public var etag: String?

    public struct Flag: Sendable, Hashable, Codable {
        public var key: String
        /// `nil` when the flag is disabled (use your own default) or failed (see `errorCode`).
        public var value: JSONValue?
        public var variant: String?
        public var reason: Reason?
        public var errorCode: EvaluationErrorCode?
        public var errorDetails: String?
        /// e.g. `["experiment": true]` for flags marked as A/B tests.
        public var metadata: [String: JSONValue]?

        /// Marked as an A/B test, e.g. to log exposures only for these.
        public var isExperiment: Bool { metadata?["experiment"] == true }
    }

    public init(flags: [Flag], etag: String? = nil) {
        self.flags = Dictionary(flags.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        self.etag = etag
    }

    private enum CodingKeys: String, CodingKey { case flags, etag }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            flags: try container.decode([Flag].self, forKey: .flags),
            etag: try container.decodeIfPresent(String.self, forKey: .etag)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(flags.values.sorted { $0.key < $1.key }, forKey: .flags)
        try container.encodeIfPresent(etag, forKey: .etag)
    }

    public subscript(key: String) -> Flag? { flags[key] }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        if case .bool(let value)? = self[key]?.value { value } else { defaultValue }
    }

    public func string(_ key: String, default defaultValue: String) -> String {
        self[key]?.value?.stringValue ?? defaultValue
    }

    /// Any number. JSON doesn't tell `0` from `0.0`, so whole numbers count too.
    public func double(_ key: String, default defaultValue: Double) -> Double {
        self[key]?.value?.numberValue ?? defaultValue
    }

    /// Whole numbers only: `2.5` gives you your default.
    public func int(_ key: String, default defaultValue: Int) -> Int {
        self[key]?.value?.numberValue.flatMap { Int(exactly: $0) } ?? defaultValue
    }

    /// Object flags, or any value as JSON.
    public func json(_ key: String, default defaultValue: JSONValue) -> JSONValue {
        self[key]?.value ?? defaultValue
    }
}
