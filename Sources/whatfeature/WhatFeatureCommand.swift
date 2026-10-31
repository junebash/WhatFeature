import ArgumentParser

@main
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
