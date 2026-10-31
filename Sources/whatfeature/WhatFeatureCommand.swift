import ArgumentParser
import Foundation
import Hummingbird
import WhatFeatureServer
import WhatFeatureStorage

@main
struct WhatFeatureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whatfeature",
        abstract: "A small feature flag service.",
        subcommands: [Serve.self, TokenCommand.self],
        defaultSubcommand: Serve.self
    )
}

struct DatabaseOptions: ParsableArguments {
    @Option(name: .customLong("database"), help: "SQLite file to use, or ':memory:' for a throwaway database. Env: DATABASE_PATH.")
    var path: String = ProcessInfo.processInfo.environment["DATABASE_PATH"] ?? "whatfeature.sqlite"

    func open() throws -> SQLiteStore {
        path == ":memory:" ? try SQLiteStore.inMemory() : try SQLiteStore(path: path)
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the server.")

    @OptionGroup var database: DatabaseOptions

    @Option(help: "Address to listen on. Env: HOST.")
    var host: String = ProcessInfo.processInfo.environment["HOST"] ?? "127.0.0.1"

    @Option(help: "Port to listen on. Env: PORT.")
    var port: Int = ProcessInfo.processInfo.environment["PORT"].flatMap(Int.init) ?? 8080

    @Option(help: "JSON file of projects, environments, tokens and flags to load at startup (development only). Env: SEED_FILE.")
    var seed: String?

    func run() async throws {
        let store = try database.open()
        if let seedPath = seed ?? ProcessInfo.processInfo.environment["SEED_FILE"] {
            try await store.load(Seed.read(from: URL(fileURLWithPath: seedPath)))
        }
        let app = buildApplication(
            store: store,
            configuration: .init(address: .hostname(host, port: port), serverName: "WhatFeature")
        )
        try await app.runService()
    }
}

struct TokenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Create, list and revoke tokens.",
        subcommands: [Create.self, List.self, Revoke.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a token and print its secret (shown only once).",
            discussion: "Admin token: --admin. Evaluation token: --project and --environment."
        )

        @OptionGroup var database: DatabaseOptions

        @Option(help: "A label, e.g. \"June's laptop\" or \"iOS app\".")
        var name: String

        @Flag(help: "Create an admin token.")
        var admin = false

        @Option(help: "Project key, for an evaluation token.")
        var project: String?

        @Option(help: "Environment key, for an evaluation token.")
        var environment: String?

        func validate() throws {
            switch (admin, project, environment) {
            case (true, nil, nil), (false, .some, .some): break
            case (true, _, _): throw ValidationError("--admin can't be combined with --project or --environment.")
            default: throw ValidationError("Pass --admin, or both --project and --environment.")
            }
        }

        func run() async throws {
            let store = try database.open()
            let actor = AuditActor.system("cli")
            let created: SQLiteStore.CreatedToken
            if admin {
                created = try await store.createAdminToken(name: name, by: actor)
            } else if let project, let environment {
                guard let projectModel = try await store.project(key: project) else {
                    throw ValidationError("No project with key '\(project)'.")
                }
                guard let environmentModel = try await store.environment(key: environment, in: projectModel.id) else {
                    throw ValidationError("No environment '\(environment)' in project '\(project)'.")
                }
                created = try await store.createEvaluationToken(name: name, for: environmentModel.id, by: actor)
            } else {
                return
            }
            print("""
            Created \(created.token.kind.rawValue) token \(created.token.id) ("\(created.token.name)").
            Secret (save it now; it won't be shown again):

                \(created.secret)
            """)
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List tokens. Never shows secrets.")

        @OptionGroup var database: DatabaseOptions

        func run() async throws {
            let tokens = try await database.open().tokens()
            if tokens.isEmpty {
                print("No tokens.")
                return
            }
            for token in tokens {
                let state = token.isRevoked ? "revoked" : "active"
                let lastUsed = token.lastUsedAt.map { "last used \($0.formatted(.iso8601))" } ?? "never used"
                print("\(token.id)  \(token.kind.rawValue)  \(state)  \(lastUsed)  \"\(token.name)\"")
            }
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke a token by ID. Takes effect immediately, even on a running server.")

        @OptionGroup var database: DatabaseOptions

        @Argument(help: "The token ID (from `whatfeature token list`).")
        var id: String

        func run() async throws {
            let token = try await database.open().revokeToken(TokenID(id), by: .system("cli"))
            print("Revoked \(token.kind.rawValue) token \(token.id) (\"\(token.name)\").")
        }
    }
}
