public import Foundation
public import WhatFeatureCore

/// A JSON file of environments, tokens and flags to load at startup. For local development only:
/// tokens are written in plain text. See `examples/seed.json`.
public struct Seed: Sendable, Decodable {
    public var environments: [Environment]

    public struct Environment: Sendable, Decodable {
        public var id: String
        public var evaluationTokens: [String]
        public var flags: [SeedFlag]
    }

    /// A flag plus its config for this environment. Leaves out the fields the server fills in.
    public struct SeedFlag: Sendable, Decodable {
        public var key: String
        public var type: FlagType
        public var variants: [String: JSONValue]
        public var description: String?
        public var isExperiment: Bool?
        public var config: FlagConfig
    }

    public static func read(from url: URL) throws -> Seed {
        try JSONDecoder().decode(Seed.self, from: Data(contentsOf: url))
    }
}

public struct SeedError: Error, CustomStringConvertible {
    public var issues: [String]

    public var description: String {
        "Seed file has problems:\n" + issues.map { "- \($0)" }.joined(separator: "\n")
    }
}

extension InMemoryStore {
    /// Loads every environment in the seed. Reports all invalid flags at once.
    public func load(_ seed: Seed, now: Date = Date()) throws(SeedError) {
        var issues: [String] = []
        for environment in seed.environments {
            let id = EnvironmentID(environment.id)
            for token in environment.evaluationTokens {
                addEvaluationToken(token, for: id)
            }
            for seedFlag in environment.flags {
                let flag = Flag(
                    key: seedFlag.key,
                    type: seedFlag.type,
                    variants: seedFlag.variants,
                    description: seedFlag.description ?? "",
                    isExperiment: seedFlag.isExperiment ?? false,
                    createdBy: "seed",
                    createdAt: now
                )
                do {
                    try put(flag, config: seedFlag.config, in: id)
                } catch {
                    issues += error.issues.map { "\(environment.id)/\(seedFlag.key): \($0)" }
                }
            }
        }
        if !issues.isEmpty { throw SeedError(issues: issues) }
    }
}
