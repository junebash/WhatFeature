import ArgumentParser
import Foundation
import Hummingbird
import WhatFeatureServer

@main
struct WhatFeatureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whatfeature",
        abstract: "A small feature flag service.",
        subcommands: [Serve.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the server.")

    @Option(help: "Address to listen on. Env: HOST.")
    var host: String = ProcessInfo.processInfo.environment["HOST"] ?? "127.0.0.1"

    @Option(help: "Port to listen on. Env: PORT.")
    var port: Int = ProcessInfo.processInfo.environment["PORT"].flatMap(Int.init) ?? 8080

    @Option(help: "JSON file of environments, tokens and flags to load (development only). Env: SEED_FILE.")
    var seed: String?

    func run() async throws {
        let store = InMemoryStore()
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
