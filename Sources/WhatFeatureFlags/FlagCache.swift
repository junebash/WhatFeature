import Crypto
public import Foundation
import WhatFeatureCore

/// Where a `FlagClient` keeps the last flags it got, so an app has values at launch before the network
/// answers, and when it's offline. Modeled on LaunchDarkly's iOS SDK: one entry per environment and
/// targeting key, written after every successful fetch, never cleared by a failed one, and only the most
/// recently written few kept.
///
/// Each entry is a JSON file named by a hash of the token and targeting key, so no user ID appears in a
/// file name. Apps usually pass a folder in Caches:
///
/// ```swift
/// let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
/// let cache = FlagCache(directory: caches.appending(path: "WhatFeature"))
/// ```
public struct FlagCache: Sendable {
    public var directory: URL
    /// How many targeting keys to keep, newest first. LaunchDarkly's default.
    public var maxContexts: Int

    public init(directory: URL, maxContexts: Int = 5) {
        self.directory = directory
        self.maxContexts = maxContexts
    }

    private struct Entry: Codable {
        var context: EvaluationContext
        var flags: Flags
    }

    /// The flags last saved for this targeting key. If the context's other attributes have changed since,
    /// they're still the best guess, but the ETag is dropped so the next fetch gets fresh values.
    func load(token: String, context: EvaluationContext) throws -> Flags? {
        let file = file(token: token, context: context)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
        var flags = entry.flags
        if entry.context != context { flags.etag = nil }
        return flags
    }

    func save(_ flags: Flags, token: String, context: EvaluationContext) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(context: context, flags: flags)).write(to: file(token: token, context: context), options: .atomic)

        // Keep the most recently written `maxContexts` entries.
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
        let newestFirst = try files.sorted {
            let dates = try [$0, $1].map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast }
            return dates[0] > dates[1]
        }
        for old in newestFirst.dropFirst(max(maxContexts, 1)) {
            try? fileManager.removeItem(at: old)
        }
    }

    private func file(token: String, context: EvaluationContext) -> URL {
        let hash = SHA256.hash(data: Data((token + "\n" + (context.targetingKey ?? "")).utf8))
        return directory.appending(path: hash.map { String(format: "%02x", $0) }.joined() + ".json")
    }
}
