import ArgumentParser
import Foundation

@main
enum Main {
    static func main() async {
        exit(await runWhatFeature(Array(CommandLine.arguments.dropFirst())))
    }
}

/// Parses and runs one command, with `CLIContext.current`. Help goes to standard output and errors to standard
/// error, as ArgumentParser's own `main` would do. Returns the exit code. Tests call this directly.
func runWhatFeature(_ arguments: [String]) async -> Int32 {
    let terminal = CLIContext.current.terminal
    do {
        var command = try WhatFeatureCommand.parseAsRoot(arguments)
        if var command = command as? any AsyncParsableCommand {
            try await command.run()
        } else {
            try command.run()
        }
        return ExitCode.success.rawValue
    } catch {
        let code = WhatFeatureCommand.exitCode(for: error)
        let message = WhatFeatureCommand.fullMessage(for: error)
        if !message.isEmpty {
            if code == .success {
                terminal.write(message + "\n")
            } else {
                terminal.writeError(message + "\n")
            }
        }
        return code.rawValue
    }
}

struct WhatFeatureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whatfeature",
        abstract: "A small feature flag service.",
        discussion: """
        Admin commands talk to a running server over its admin API. Run `whatfeature login` once, \
        or set WHATFEATURE_URL and WHATFEATURE_TOKEN. The `db` commands work on the database file \
        directly, for creating the first admin token.
        """,
        subcommands: [
            Serve.self,
            Login.self, Logout.self, WhoAmI.self,
            ProjectsCommand.self, EnvironmentsCommand.self, FlagsCommand.self, ConfigCommand.self,
            Evaluate.self, TokensCommand.self, AuditCommand.self,
            DatabaseCommand.self,
        ],
        defaultSubcommand: Serve.self
    )
}
