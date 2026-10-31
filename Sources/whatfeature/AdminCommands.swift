public import ArgumentParser
import Foundation
import WhatFeatureAPI
public import WhatFeatureClient
public import WhatFeatureCore
import WhatFeatureStorage

// MARK: - Login

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save the server URL and an admin token for the other commands.",
        discussion: "Checks the token first. Saved to ~/.config/whatfeature/config.json, readable only by you."
    )

    @Option(help: "Server URL.")
    var url: String = "http://127.0.0.1:8080"

    @Option(help: "Admin token. Leave out to paste it at a prompt instead (keeps it out of your shell history).")
    var token: String?

    @Option(name: [.short, .long], help: "A default project for commands that need one.")
    var project: String?

    func run() async throws {
        let context = CLIContext.current
        var secret = token
        if secret == nil {
            writeLine("Admin token:", terminator: " ")
            secret = try await context.terminal.readLine()?.trimmingCharacters(in: .whitespaces)
        }
        guard let secret, !secret.isEmpty else { throw ValidationError("No token given.") }

        let client = try await ConnectionOptions(url: url, token: secret).makeClient()
        let me = try await withServer(client) { try await $0.me() }
        if let project {
            _ = try await withServer(client) { try await $0.project(project) }
        }
        try await context.saveSettings(SavedSettings(url: url, token: secret, project: project))
        writeLine("Logged in to \(url) as \(me.kind.rawValue) token \"\(me.name)\" (\(me.id)).")
        if let project { writeLine("Default project: \(project)") }
    }
}

extension ConnectionOptions {
    init(url: String?, token: String?) {
        self.init()
        self.url = url
        self.token = token
    }
}

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Forget the saved URL and token.")

    func run() async throws {
        let context = CLIContext.current
        if try await context.removeSettings() {
            writeLine("Removed \(context.settingsFile.path).")
        } else {
            writeLine("Not logged in.")
        }
    }
}

struct WhoAmI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "whoami", abstract: "Show which server and token the CLI is using.")

    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let client = try await connection.makeClient()
        let me = try await withServer(client) { try await $0.me() }
        writeLine("\(client.baseURL.absoluteString) as \(me.kind.rawValue) token \"\(me.name)\" (\(me.id))")
    }
}

// MARK: - Projects

struct ProjectsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "projects",
        abstract: "List and create projects.",
        subcommands: [List.self, Show.self, Create.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let projects = try await withServer(try await connection.makeClient()) { try await $0.projects() }
            if output.json { return try printJSON(projects) }
            if projects.isEmpty { return writeLine("No projects.") }
            printTable(["KEY", "NAME", "CREATED"], projects.map { [$0.key, $0.name, format($0.createdAt)] })
        }
    }

    struct Show: AsyncParsableCommand {
        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var output: OutputOptions
        @Argument(help: "Project key.") var key: String

        func run() async throws {
            let client = try await connection.makeClient()
            let (project, environments) = try await withServer(client) { client in
                (try await client.project(key), try await client.environments(project: key))
            }
            if output.json { return try printJSON(project) }
            writeLine("\(project.key): \(project.name)")
            writeLine("Environments: " + (environments.isEmpty ? "none" : environments.map(\.key).joined(separator: ", ")))
        }
    }

    struct Create: AsyncParsableCommand {
        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var output: OutputOptions
        @Argument(help: "Project key, e.g. my-app.") var key: String
        @Option(help: "Display name. Defaults to the key.") var name: String?

        func run() async throws {
            let project = try await withServer(try await connection.makeClient()) { try await $0.createProject(key: key, name: name) }
            if output.json { return try printJSON(project) }
            writeLine("Created project \(project.key). Next: `whatfeature environments create dev -p \(project.key)`")
        }
    }
}

// MARK: - Environments

struct EnvironmentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "environments",
        abstract: "List and create environments.",
        subcommands: [List.self, Create.self],
        defaultSubcommand: List.self,
        aliases: ["envs"]
    )

    struct List: AsyncParsableCommand {
        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let projectKey = try await project.resolve()
            let environments = try await withServer(try await connection.makeClient()) { try await $0.environments(project: projectKey) }
            if output.json { return try printJSON(environments) }
            if environments.isEmpty { return writeLine("No environments in \(projectKey).") }
            printTable(["KEY", "NAME", "VERSION", "CREATED"], environments.map { [$0.key, $0.name, "v\($0.version)", format($0.createdAt)] })
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(discussion: "Every existing flag gets a disabled config in the new environment.")

        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @OptionGroup var output: OutputOptions
        @Argument(help: "Environment key, e.g. dev or prod.") var key: String
        @Option(help: "Display name. Defaults to the key.") var name: String?

        func run() async throws {
            let projectKey = try await project.resolve()
            let environment = try await withServer(try await connection.makeClient()) {
                try await $0.createEnvironment(project: projectKey, key: key, name: name)
            }
            if output.json { return try printJSON(environment) }
            writeLine("Created environment \(environment.key) in \(projectKey).")
        }
    }
}

// MARK: - Flags

struct FlagsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flags",
        abstract: "List, create, change and remove flags.",
        subcommands: [List.self, Show.self, Create.self, Update.self, Archive.self, Unarchive.self, Delete.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @OptionGroup var output: OutputOptions
        @Flag(help: "Include archived flags.") var archived = false
        @Option(help: "Only flags created by this actor, e.g. token:<id>.") var createdBy: String?
        @Option(help: "Sort by key or createdAt.") var sort: AdminClient.FlagSort = .key
        @Flag(help: "Reverse the order.") var desc = false

        func run() async throws {
            let projectKey = try await project.resolve()
            let flags = try await withServer(try await connection.makeClient()) {
                try await $0.flags(project: projectKey, includeArchived: archived, createdBy: createdBy, sort: sort, descending: desc)
            }
            if output.json { return try printJSON(flags) }
            printFlags(flags)
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a flag and its state in every environment.")

        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @OptionGroup var output: OutputOptions
        @Argument(help: "Flag key.") var key: String

        func run() async throws {
            let projectKey = try await project.resolve()
            let detail = try await withServer(try await connection.makeClient()) { try await $0.flag(project: projectKey, key: key) }
            if output.json { return try printJSON(detail) }
            printFlagDetail(detail)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a flag. It starts disabled in every environment.",
            discussion: """
            Boolean flags get on=true and off=false unless you list variants. Values follow the flag type:
              --type string --variant short=Hi --variant long="Welcome back"
              --type number --variant low=1 --variant high=10
              --type object --variant dark='{"background": "#000"}'
            """
        )

        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @OptionGroup var output: OutputOptions
        @Argument(help: "Flag key, e.g. new-onboarding.") var key: String
        @Option(help: "boolean, string, number or object.") var type: FlagType = .boolean
        @Option(name: .customLong("variant"), help: "A variant as name=value. Repeat for each.") var variants: [String] = []
        @Option(help: "What the flag is for.") var description: String?
        @Flag(help: "Mark the flag as an A/B test.") var experiment = false
        @Option(name: .customLong("default"), help: "The variant to serve once enabled. Default: the first variant name alphabetically (off, for on/off flags).")
        var defaultVariant: String?

        func run() async throws {
            let projectKey = try await project.resolve()
            var parsed = try parseVariants(variants, type: type)
            if parsed.isEmpty, type == .boolean {
                parsed = ["on": true, "off": false]
            }
            let request = CreateFlagRequest(
                key: key, type: type, variants: parsed, description: description, isExperiment: experiment, defaultVariant: defaultVariant
            )
            let detail = try await withServer(try await connection.makeClient()) { try await $0.createFlag(project: projectKey, request) }
            if output.json { return try printJSON(detail) }
            printFlagDetail(detail)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a flag's description, variants or experiment marker.",
            discussion: "--variant replaces the whole set. A variant still used by a config can't be removed."
        )

        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @OptionGroup var output: OutputOptions
        @Argument(help: "Flag key.") var key: String
        @Option(help: "New description.") var description: String?
        @Option(name: .customLong("variant"), help: "A variant as name=value. Repeat for each; replaces all variants.") var variants: [String] = []
        @Flag(inversion: .prefixedNo, help: "Mark or unmark the flag as an A/B test.") var experiment: Bool?

        func run() async throws {
            let projectKey = try await project.resolve()
            let client = try await connection.makeClient()
            var changes = SQLiteStore.FlagChanges(description: description, isExperiment: experiment)
            if !variants.isEmpty {
                let current = try await withServer(client) { try await $0.flag(project: projectKey, key: key) }
                changes.variants = try parseVariants(variants, type: current.flag.type)
            }
            guard changes != SQLiteStore.FlagChanges() else {
                throw ValidationError("Nothing to change. Pass --description, --variant, or --experiment / --no-experiment.")
            }
            let detail = try await withServer(client) { try await $0.updateFlag(project: projectKey, key: key, changes: changes) }
            if output.json { return try printJSON(detail) }
            printFlagDetail(detail)
        }
    }

    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Archive a flag: it evaluates as disabled everywhere and drops out of lists.")

        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @Argument(help: "Flag key.") var key: String

        func run() async throws {
            let projectKey = try await project.resolve()
            _ = try await withServer(try await connection.makeClient()) { try await $0.setArchived(true, project: projectKey, key: key) }
            writeLine("Archived \(key). Apps now get their own default for it.")
        }
    }

    struct Unarchive: AsyncParsableCommand {
        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @Argument(help: "Flag key.") var key: String

        func run() async throws {
            let projectKey = try await project.resolve()
            _ = try await withServer(try await connection.makeClient()) { try await $0.setArchived(false, project: projectKey, key: key) }
            writeLine("Unarchived \(key). Its configs are as they were.")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a flag and its configs everywhere. Can't be undone; consider archiving instead."
        )

        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @Argument(help: "Flag key.") var key: String
        @Flag(help: "Don't ask for confirmation.") var yes = false

        func run() async throws {
            let projectKey = try await project.resolve()
            let question = "Delete '\(key)' from every environment of \(projectKey)? Type the flag key to confirm:"
            if !yes, try await !confirm(question, expecting: key) {
                throw CLIError("Not deleted. (Pass --yes to skip the question.)")
            }
            try await withServer(try await connection.makeClient()) { try await $0.deleteFlag(project: projectKey, key: key) }
            writeLine("Deleted \(key).")
        }
    }
}

// MARK: - Configs

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "See and change how a flag behaves in one environment.",
        subcommands: [Show.self, Enable.self, Disable.self, Serve.self, Rollout.self, Set.self]
    )

    /// The arguments every config command takes.
    struct Target: ParsableArguments {
        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var project: ProjectOption
        @OptionGroup var environment: EnvironmentOption
        @Argument(help: "Flag key.") var flag: String
    }

    /// Fetches the current config, changes it, saves it, and prints the result.
    static func change(_ target: Target, _ edit: (inout FlagConfig) -> Void) async throws {
        let projectKey = try await target.project.resolve()
        let environment = target.environment.environment
        let saved = try await withServer(try target.connection.makeClient()) { client in
            var config = try await client.config(project: projectKey, environment: environment, flag: target.flag)
            edit(&config)
            return try await client.setConfig(config, project: projectKey, environment: environment, flag: target.flag)
        }
        writeLine("\(target.flag) in \(environment): \(saved.enabled ? "enabled" : "disabled"), \(summary(of: saved)) (v\(saved.version))")
    }

    struct Show: AsyncParsableCommand {
        @OptionGroup var target: Target
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let projectKey = try await target.project.resolve()
            let config = try await withServer(try target.connection.makeClient()) {
                try await $0.config(project: projectKey, environment: target.environment.environment, flag: target.flag)
            }
            if output.json { return try printJSON(config) }
            try printConfig(config, environment: target.environment.environment, flag: target.flag)
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn the flag on in this environment, keeping its rules.")
        @OptionGroup var target: Target
        func run() async throws { try await ConfigCommand.change(target) { $0.enabled = true } }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn the flag off (the kill switch). Apps get their own default.")
        @OptionGroup var target: Target
        func run() async throws { try await ConfigCommand.change(target) { $0.enabled = false } }
    }

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give everyone one variant: clears the rules, sets the default, and enables the flag.",
            discussion: "e.g. `whatfeature config serve dark-mode on -e prod`"
        )
        @OptionGroup var target: Target
        @Argument(help: "Variant name.") var variant: String

        func run() async throws {
            try await ConfigCommand.change(target) { config in
                config.rules = []
                config.defaultResult = .variant(variant)
                config.enabled = true
            }
        }
    }

    struct Rollout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Split the default between variants by percentage, keeping any rules, and enable the flag.",
            discussion: """
            e.g. `whatfeature config rollout dark-mode on=10 off=90 -e prod`. Shares must add up to 100.
            Raising `on` later (say to 20) keeps the first 10% in; see docs/DESIGN.md on bucketing.
            """
        )
        @OptionGroup var target: Target
        @Argument(help: "Shares as variant=percent.") var shares: [String]

        func run() async throws {
            let rollout = try parseRollout(shares)
            try await ConfigCommand.change(target) { config in
                config.defaultResult = .rollout(rollout)
                config.enabled = true
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace the whole config with JSON from a file, standard input (-), or --json.",
            discussion: "Tip: `whatfeature config show <flag> -e dev --json > config.json`, edit it, then `config set <flag> -e dev config.json`."
        )
        @OptionGroup var target: Target
        @Argument(help: "A JSON file, or - for standard input.") var file: String?
        @Option(help: "The config as a JSON string.") var json: String?

        func validate() throws {
            if (file == nil) == (json == nil) { throw ValidationError("Pass a file (or -), or --json, but not both.") }
        }

        func run() async throws {
            let data: Data
            if let json {
                data = Data(json.utf8)
            } else {
                data = try await readInput(file ?? "-")
            }
            let config: FlagConfig
            do {
                config = try JSONDecoder().decode(FlagConfig.self, from: data)
            } catch let error as DecodingError {
                throw CLIError("That isn't a valid flag config: \(error)")
            }
            try await ConfigCommand.change(target) { $0 = config }
        }
    }
}

// MARK: - Evaluate

struct Evaluate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show what a user or device would get, and why. Stores nothing.",
        discussion: """
        e.g. whatfeature evaluate dark-mode -e prod --targeting-key user-123 --attr appVersion=3.1
             whatfeature evaluate --all -e prod --targeting-key user-123
        --attr values are always strings (so app versions stay versions). Use --attr-json for numbers,
        booleans or objects, e.g. --attr-json age=30.
        --app-json prints exactly the JSON an app would get from the OFREP endpoint, and nothing else.
        """
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var project: ProjectOption
    @OptionGroup var environment: EnvironmentOption
    @OptionGroup var output: OutputOptions
    @Argument(help: "Flag key. Leave out with --all.") var flag: String?
    @Flag(help: "Every flag at once, as the app's bulk request would get them.") var all = false
    @Flag(help: "Print exactly the JSON an app would get, and nothing else.") var appJSON = false
    @Option(help: "The targeting key (user or device ID).") var targetingKey: String?
    @Option(name: .customLong("attr"), help: "A string attribute, name=value. Repeat for more.") var attributes: [String] = []
    @Option(name: .customLong("attr-json"), help: "A JSON attribute, name=value. Repeat for more.") var jsonAttributes: [String] = []
    @Option(help: "The whole context as a JSON object. --targeting-key and --attr are added on top.") var context: String?

    func validate() throws {
        switch (flag, all) {
        case (nil, false): throw ValidationError("Give a flag key, or --all for every flag.")
        case (.some, true): throw ValidationError("Give a flag key or --all, not both.")
        default: break
        }
        if appJSON, output.json { throw ValidationError("Use --json or --app-json, not both.") }
    }

    func run() async throws {
        let projectKey = try await project.resolve()
        let evaluationContext = try buildContext(json: context, targetingKey: targetingKey, attributes: attributes, jsonAttributes: jsonAttributes)
        let client = try await connection.makeClient()

        guard let flag else {
            let results = try await withServer(client) {
                try await $0.evaluateAll(project: projectKey, environment: environment.environment, context: evaluationContext)
            }
            if appJSON { return writeLine(appJSONString(results.ofrep.body)) }
            if output.json { return try printJSON(results) }
            printDryRuns(results.flags)
            return
        }

        let result = try await withServer(client) {
            try await $0.evaluate(project: projectKey, environment: environment.environment, flag: flag, context: evaluationContext)
        }
        if appJSON { return writeLine(appJSONString(result.ofrep.body)) }
        if output.json { return try printJSON(result) }
        printDryRun(result)
    }
}

// MARK: - Tokens

struct TokensCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tokens",
        abstract: "List, create and revoke tokens through the server.",
        subcommands: [List.self, Create.self, Revoke.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let tokens = try await withServer(try await connection.makeClient()) { try await $0.tokens() }
            if output.json { return try printJSON(tokens) }
            printTokens(tokens)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a token and print its secret (shown only once).",
            discussion: "Admin token: --admin. Evaluation token (for an app): --project and --env."
        )

        @OptionGroup var connection: ConnectionOptions
        @OptionGroup var output: OutputOptions
        @Option(help: "A label, e.g. \"iOS app\".") var name: String
        @Flag(help: "Create an admin token.") var admin = false
        @Option(name: [.short, .long], help: "Project key, for an evaluation token. Env: WHATFEATURE_PROJECT.") var project: String?
        @Option(name: [.short, .customLong("env"), .customLong("environment")], help: "Environment key, for an evaluation token.") var environment: String?

        func run() async throws {
            let request: CreateTokenRequest
            if admin {
                guard environment == nil, project == nil else { throw ValidationError("--admin can't be combined with --project or --env.") }
                request = CreateTokenRequest(name: name, kind: .admin)
            } else {
                guard let environment else { throw ValidationError("Pass --admin, or --env (and --project) for an evaluation token.") }
                let projectKey = try await ProjectOption(project: project).resolve()
                request = CreateTokenRequest(name: name, kind: .evaluation, project: projectKey, environment: environment)
            }
            let created = try await withServer(try await connection.makeClient()) { try await $0.createToken(request) }
            if output.json { return try printJSON(created) }
            printCreatedToken(created.token, secret: created.secret)
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke a token by ID. Takes effect immediately.")

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "Token ID (from `whatfeature tokens list`).") var id: String

        func run() async throws {
            let token = try await withServer(try await connection.makeClient()) { try await $0.revokeToken(TokenID(id)) }
            writeLine("Revoked \(token.kind.rawValue) token \(token.id) (\"\(token.name)\").")
        }
    }
}

extension ProjectOption {
    init(project: String?) {
        self.init()
        self.project = project
    }
}

// MARK: - Audit

struct AuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Show who changed what, newest first. Use --json to see before/after."
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: OutputOptions
    @Option(name: [.short, .long], help: "Only this project.") var project: String?
    @Option(help: "Only this flag.") var flag: String?
    @Option(help: "Only this actor, e.g. token:<id> or system:seed.") var actor: String?
    @Option(help: "From this time on (ISO 8601).") var since: String?
    @Option(help: "Before this time (ISO 8601).") var until: String?
    @Option(help: "At most this many entries (1–1000).") var limit: Int = 50

    func run() async throws {
        func date(_ text: String?, _ name: String) throws -> Date? {
            guard let text else { return nil }
            guard let date = try? Date(text, strategy: .iso8601) else {
                throw ValidationError("--\(name) must be an ISO 8601 time, like 2026-10-31T12:00:00Z.")
            }
            return date
        }
        let sinceDate = try date(since, "since")
        let untilDate = try date(until, "until")
        let entries = try await withServer(try await connection.makeClient()) {
            try await $0.audit(project: project, flag: flag, actor: actor, since: sinceDate, until: untilDate, limit: limit)
        }
        if output.json { return try printJSON(entries) }
        if entries.isEmpty { return writeLine("No audit entries.") }
        printTable(
            ["TIME", "ACTOR", "ACTION", "FLAG"],
            entries.map { [format($0.timestamp), $0.actor, $0.action, $0.flagKey ?? ""] }
        )
    }
}

extension FlagType: ExpressibleByArgument {}
extension AdminClient.FlagSort: ExpressibleByArgument {}
