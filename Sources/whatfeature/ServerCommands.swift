import ArgumentParser
import Foundation
import Hummingbird
import NIOPosix
import WhatFeatureServer
import WhatFeatureStorage

struct DatabaseOptions: ParsableArguments {
    @Option(
        name: .customLong("database"),
        help: "SQLite file to use, or ':memory:' for a throwaway database. Env: DATABASE_PATH. (default: whatfeature.sqlite)"
    )
    var path: String?

    func open() throws -> SQLiteStore {
        let path = path ?? CLIContext.current.environment["DATABASE_PATH"] ?? "whatfeature.sqlite"
        return path == ":memory:" ? try SQLiteStore.inMemory() : try SQLiteStore(path: path)
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the server.")

    @OptionGroup var database: DatabaseOptions

    @Option(help: "Address to listen on. Env: HOST. (default: 127.0.0.1)")
    var host: String?

    @Option(help: "Port to listen on. Env: PORT. (default: 8080)")
    var port: Int?

    @Option(help: "JSON file of projects, environments, tokens and flags to load at startup (development only). Env: SEED_FILE.")
    var seed: String?

    @Option(help: "Requests per minute for each admin token, or 'off'. Env: RATE_LIMIT_ADMIN. (default: \(RateLimit.adminDefault.requestsPerMinute))")
    var adminRateLimit: String?

    func run() async throws {
        let context = CLIContext.current
        let host = host ?? context.environment["HOST"] ?? "127.0.0.1"
        let port = try port ?? context.environment["PORT"].map { text in
            guard let port = Int(text) else { throw ValidationError("PORT must be a number, not '\(text)'.") }
            return port
        } ?? 8080
        var rateLimit: RateLimit? = .adminDefault
        if let text = adminRateLimit ?? context.environment["RATE_LIMIT_ADMIN"] {
            rateLimit = try parseRateLimit(text)
        }

        let store = try database.open()
        if let seedPath = seed ?? context.environment["SEED_FILE"] {
            let seed = try await context.threadPool.runIfActive { try Seed.read(from: URL(fileURLWithPath: seedPath)) }
            try await store.load(seed)
        }
        let app = buildApplication(
            store: store,
            configuration: .init(address: .hostname(host, port: port), serverName: "WhatFeature"),
            adminRateLimit: rateLimit
        )
        try await app.runService()
    }
}

/// Works on the database file directly instead of through the server. Mainly for the first admin token,
/// which can't come from the admin API because nothing can call it yet.
struct DatabaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Work on the database file directly (e.g. to create the first admin token).",
        discussion: "Only tokens are managed this way: a running server picks up token changes immediately, but not flag changes.",
        subcommands: [Token.self]
    )

    struct Token: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create, list and revoke tokens in the database file.",
            subcommands: [Create.self, List.self, Revoke.self]
        )

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Create a token and print its secret (shown only once).",
                discussion: "Admin token: --admin. Evaluation token: --project and --env."
            )

            @OptionGroup var database: DatabaseOptions

            @Option(help: "A label, e.g. \"June's laptop\" or \"iOS app\".")
            var name: String

            @Flag(help: "Create an admin token.")
            var admin = false

            @Option(help: "Project key, for an evaluation token.")
            var project: String?

            @Option(name: [.customLong("env"), .customLong("environment")], help: "Environment key, for an evaluation token.")
            var environment: String?

            func validate() throws {
                switch (admin, project, environment) {
                case (true, nil, nil), (false, .some, .some): break
                case (true, _, _): throw ValidationError("--admin can't be combined with --project or --env.")
                default: throw ValidationError("Pass --admin, or both --project and --env.")
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
                try await printCreatedToken(created.token, secret: created.secret)
            }
        }

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List tokens. Never shows secrets.")

            @OptionGroup var database: DatabaseOptions

            func run() async throws {
                try await printTokens(try await database.open().tokens())
            }
        }

        struct Revoke: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Revoke a token by ID. Takes effect immediately, even on a running server.")

            @OptionGroup var database: DatabaseOptions

            @Argument(help: "The token ID (from `whatfeature db token list`).")
            var id: String

            func run() async throws {
                let token = try await database.open().revokeToken(TokenID(id), by: .system("cli"))
                try await writeLine("Revoked \(token.kind.rawValue) token \(token.id) (\"\(token.name)\").")
            }
        }
    }
}
