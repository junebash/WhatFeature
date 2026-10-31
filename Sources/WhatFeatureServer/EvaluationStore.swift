public import WhatFeatureCore

/// Identifies one environment (e.g. a project's `prod`).
public struct EnvironmentID: Sendable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// What the evaluation endpoints need from storage. The SQLite store will implement this too.
public protocol EvaluationStore: Sendable {
    /// The environment an evaluation token can read, or `nil` for an unknown or revoked token.
    /// Takes the token's hash (see `TokenHash`), never the secret itself.
    func environment(forTokenHash tokenHash: String) async throws -> EnvironmentID?

    /// Every flag in the environment. An environment with no flags returns an empty snapshot.
    func snapshot(for environment: EnvironmentID) async throws -> EnvironmentSnapshot
}
