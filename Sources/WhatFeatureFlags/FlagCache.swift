import Crypto
public import Foundation
import WhatFeatureCore

/// Where a `FlagClient` keeps the last flags it got, so an app has values at launch before the network
/// answers, and when it's offline. Modeled on LaunchDarkly's iOS SDK: one entry per environment and
/// targeting key, written after every successful fetch, never cleared by a failed one, and only the most
/// recently written few kept.
///
/// Entries are named by a hash of the token and targeting key, so no user ID appears in a file name. Apps
/// usually pass a folder in Caches:
///
/// ```swift
/// let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
/// let cache = FlagCache(directory: caches.appending(path: "WhatFeature"))
/// ```
public struct FlagCache: Sendable {
    public var storage: Storage
    /// How many targeting keys to keep, most recently written first. LaunchDarkly's default.
    public var maxContexts: Int

    public init(directory: URL, maxContexts: Int = 5) {
        self.init(storage: .directory(directory), maxContexts: maxContexts)
    }

    public init(storage: Storage, maxContexts: Int = 5) {
        self.storage = storage
        self.maxContexts = maxContexts
    }

    /// Named pieces of data: files in a folder in apps (`directory(_:)`), anything in tests. `read` returns
    /// `nil` for a name that was never written.
    public struct Storage: Sendable {
        public var read: @Sendable (_ name: String) throws -> Data?
        public var write: @Sendable (_ name: String, _ data: Data) throws -> Void
        public var remove: @Sendable (_ name: String) throws -> Void

        public init(
            read: @escaping @Sendable (String) throws -> Data?,
            write: @escaping @Sendable (String, Data) throws -> Void,
            remove: @escaping @Sendable (String) throws -> Void
        ) {
            self.read = read
            self.write = write
            self.remove = remove
        }

        /// One file per name in `directory`, created when first written.
        public static func directory(_ directory: URL) -> Storage {
            Storage(
                read: { name in
                    let file = directory.appending(path: name)
                    return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
                },
                write: { name, data in
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appending(path: name), options: .atomic)
                },
                remove: { name in
                    let file = directory.appending(path: name)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
            )
        }
    }

    struct Entry: Codable {
        var context: EvaluationContext
        var flags: Flags
    }

    /// Entry name → write order (higher is newer), for keeping the newest `maxContexts`.
    typealias Index = [String: Int]
    static let indexName = "index.json"

    func load(token: String, context: EvaluationContext) throws -> Flags? {
        try storage.read(Self.entryName(token: token, context: context))
            .map { Self.flags(from: try JSONDecoder().decode(Entry.self, from: $0), for: context) }
    }

    // ponytail: two saves at once can lose one's index update; that entry then just outlives the limit.
    func save(_ flags: Flags, token: String, context: EvaluationContext) throws {
        let name = Self.entryName(token: token, context: context)
        try storage.write(name, JSONEncoder().encode(Entry(context: context, flags: flags)))
        let index = try storage.read(Self.indexName).map { try JSONDecoder().decode(Index.self, from: $0) } ?? [:]
        let (newIndex, evicted) = Self.recordingWrite(of: name, in: index, keeping: maxContexts)
        try storage.write(Self.indexName, JSONEncoder().encode(newIndex))
        for old in evicted { try? storage.remove(old) }
    }

    // MARK: - Pure parts: no I/O

    static func entryName(token: String, context: EvaluationContext) -> String {
        let hash = SHA256.hash(data: Data((token + "\n" + (context.targetingKey ?? "")).utf8))
        return hash.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// If the context's other attributes have changed since the entry was saved, its flags are still the
    /// best guess, but the ETag is dropped so the next fetch gets fresh values.
    static func flags(from entry: Entry, for context: EvaluationContext) -> Flags {
        var flags = entry.flags
        if entry.context != context { flags.etag = nil }
        return flags
    }

    /// Marks `name` as the newest entry, and drops all but the newest `limit` (at least one).
    static func recordingWrite(of name: String, in index: Index, keeping limit: Int) -> (index: Index, evicted: [String]) {
        var index = index
        index[name] = (index.values.max() ?? 0) + 1
        let evicted = index.sorted { $0.value > $1.value }.dropFirst(max(limit, 1)).map(\.key)
        for old in evicted { index[old] = nil }
        return (index, evicted)
    }
}
