public import Foundation
public import WhatFeatureCore

/// Keeps everything in memory. Used for local development (loaded from a seed file) and tests,
/// until the SQLite store exists.
public actor InMemoryStore: EvaluationStore {
    private var snapshots: [EnvironmentID: EnvironmentSnapshot] = [:]
    /// Token hash → environment.
    private var evaluationTokens: [String: EnvironmentID] = [:]
    /// Snapshot versions come from one counter that only goes up. It starts at the current time in
    /// milliseconds, so a restarted server never reuses an old version (and its old ETags).
    private var lastVersion: Int

    public init(now: Date = Date()) {
        lastVersion = Int(now.timeIntervalSince1970 * 1_000)
    }

    public func environment(forTokenHash tokenHash: String) -> EnvironmentID? {
        evaluationTokens[tokenHash]
    }

    public func snapshot(for environment: EnvironmentID) -> EnvironmentSnapshot {
        snapshots[environment] ?? EnvironmentSnapshot(version: 0, entries: [])
    }

    public func addEvaluationToken(_ secret: String, for environment: EnvironmentID) {
        evaluationTokens[TokenHash.of(secret)] = environment
    }

    /// Adds or replaces a flag in one environment, after validating it.
    public func put(_ flag: Flag, config: FlagConfig, in environment: EnvironmentID) throws(ValidationError) {
        try flag.validate()
        try config.validate(for: flag)

        var entries = snapshots[environment]?.entries ?? [:]
        entries[flag.key] = EnvironmentSnapshot.Entry(flag: flag, config: config)
        lastVersion += 1
        snapshots[environment] = EnvironmentSnapshot(version: lastVersion, entries: Array(entries.values))
    }
}
