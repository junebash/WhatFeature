public import WhatFeatureCore

/// What the evaluation endpoints need from storage. Kept small so another database (e.g. Postgres)
/// could implement it.
public protocol EvaluationStore: Sendable {
    /// The environment an evaluation token can read, or `nil` for an unknown, revoked, or admin token.
    /// Takes the token's hash (see `TokenHash`), never the secret itself.
    func environment(forTokenHash tokenHash: String) async throws -> EnvironmentID?

    /// Every flag in the environment. An unknown environment returns an empty snapshot.
    func snapshot(for environment: EnvironmentID) async throws -> EnvironmentSnapshot
}
