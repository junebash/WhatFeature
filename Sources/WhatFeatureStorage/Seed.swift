public import Foundation
public import WhatFeatureCore

/// A JSON file of projects, environments, tokens and flags to load at startup. For local development:
/// tokens are written in plain text. See `examples/seed.json`.
///
/// Loading is safe to repeat. It creates whatever is missing and updates configs that differ, so it can
/// run on every start against the same database.
public struct Seed: Sendable, Decodable {
    public var projects: [SeedProject]

    public struct SeedProject: Sendable, Decodable {
        public var key: String
        public var name: String?
        public var environments: [SeedEnvironment]
        public var flags: [SeedFlag]
    }

    public struct SeedEnvironment: Sendable, Decodable {
        public var key: String
        public var name: String?
        public var evaluationTokens: [String]?
    }

    public struct SeedFlag: Sendable, Decodable {
        public var key: String
        public var type: FlagType
        public var variants: [String: JSONValue]
        public var description: String?
        public var isExperiment: Bool?
        /// Environment key → config. Environments not listed keep the default (disabled) config.
        public var configs: [String: FlagConfig]?
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

extension SQLiteStore {
    /// Reports every invalid flag or config at once, after loading everything that was valid.
    public func load(_ seed: Seed) async throws {
        let actor = AuditActor.system("seed")
        var issues: [String] = []

        func attempt(_ location: String, _ work: () async throws -> Void) async throws {
            do {
                try await work()
            } catch let error as StoreError {
                issues.append("\(location): \(error)")
            }
        }

        for seedProject in seed.projects {
            let project: Project
            if let existing = try await self.project(key: seedProject.key) {
                project = existing
            } else {
                project = try await createProject(key: seedProject.key, name: seedProject.name ?? seedProject.key, by: actor)
            }

            var environments: [String: EnvironmentID] = [:]
            for seedEnvironment in seedProject.environments {
                let environment: Environment
                if let existing = try await self.environment(key: seedEnvironment.key, in: project.id) {
                    environment = existing
                } else {
                    environment = try await createEnvironment(
                        key: seedEnvironment.key, name: seedEnvironment.name ?? seedEnvironment.key, in: project.id, by: actor
                    )
                }
                environments[seedEnvironment.key] = environment.id
                for secret in seedEnvironment.evaluationTokens ?? [] {
                    try await importEvaluationToken(secret: secret, name: "seed", for: environment.id, by: actor)
                }
            }

            for seedFlag in seedProject.flags {
                let location = "\(seedProject.key)/\(seedFlag.key)"
                try await attempt(location) {
                    if let existing = try await flag(key: seedFlag.key, in: project.id) {
                        guard existing.type == seedFlag.type else {
                            throw StoreError.invalid(["Flag is \(existing.type.rawValue) in the database; a flag's type can't change"])
                        }
                    } else {
                        _ = try await createFlag(
                            key: seedFlag.key, type: seedFlag.type, variants: seedFlag.variants,
                            description: seedFlag.description ?? "", isExperiment: seedFlag.isExperiment ?? false,
                            in: project.id, by: actor
                        )
                    }
                }

                for (environmentKey, config) in (seedFlag.configs ?? [:]).sorted(by: { $0.key < $1.key }) {
                    try await attempt("\(location) in \(environmentKey)") {
                        guard let environmentID = environments[environmentKey] else {
                            throw StoreError.notFound("Unknown environment '\(environmentKey)'")
                        }
                        // Skip unchanged configs, so restarting doesn't bump versions (and invalidate ETags).
                        if var current = try await self.config(flagKey: seedFlag.key, in: environmentID) {
                            current.version = config.version
                            if current == config { return }
                        }
                        try await setConfig(config, flagKey: seedFlag.key, in: environmentID, by: actor)
                    }
                }
            }
        }

        if !issues.isEmpty { throw SeedError(issues: issues) }
    }
}
