import AsyncHTTPClient
import Foundation
import HummingbirdTesting
import NIOPosix
import Synchronization
import Testing
import WhatFeatureServer
import WhatFeatureStorage
@testable import whatfeature

// Commands run in this process, against a live server, with a `CLIContext` of the test's own: its own
// environment variables, settings file and terminal. Faster than running the binary, and able to test what a
// separate process can't, like answering a prompt on a terminal. (Tests/WhatFeatureIntegrationTests/CLITests
// runs the real binary.)

/// Records what's written and hands out scripted lines of input.
private final class FakeTerminal: Terminal {
    private struct State {
        var input: [String]
        var output = ""
        var errors = ""
    }

    private let state: Mutex<State>
    let isInteractive: Bool

    init(input: [String] = [], isInteractive: Bool = false) {
        state = Mutex(State(input: input))
        self.isInteractive = isInteractive
    }

    var output: String { state.withLock { $0.output } }
    var errors: String { state.withLock { $0.errors } }

    func write(_ text: String) { state.withLock { $0.output += text } }
    func writeError(_ text: String) { state.withLock { $0.errors += text } }

    func readLine() async throws -> String? {
        state.withLock { $0.input.isEmpty ? nil : $0.input.removeFirst() }
    }

    func readAll() async throws -> Data {
        Data(state.withLock { state in
            defer { state.input = [] }
            return state.input.joined(separator: "\n")
        }.utf8)
    }
}

private struct CommandResult {
    var status: Int32
    var output: String
    var errors: String
}

/// A server with one admin token, plus a settings file of the test's own.
private struct Setup: Sendable {
    var url: String
    var token: String
    var settingsFile: URL

    /// Settings as environment variables, the usual way to point the CLI at a server without `login`.
    var connected: [String: String] {
        ["WHATFEATURE_URL": url, "WHATFEATURE_TOKEN": token, "WHATFEATURE_PROJECT": "demo"]
    }

    /// Runs one command with a context of this test's own.
    @discardableResult
    func run(_ arguments: [String], environment: [String: String]? = nil, terminal: FakeTerminal = FakeTerminal()) async -> CommandResult {
        let context = CLIContext(
            environment: environment ?? connected,
            settingsFile: settingsFile,
            terminal: terminal,
            httpClient: .shared,
            threadPool: .singleton
        )
        let status = await CLIContext.$current.withValue(context) { await runWhatFeature(arguments) }
        return CommandResult(status: status, output: terminal.output, errors: terminal.errors)
    }

    @discardableResult
    func run(_ arguments: String..., environment: [String: String]? = nil, terminal: FakeTerminal = FakeTerminal()) async -> CommandResult {
        await run(arguments, environment: environment, terminal: terminal)
    }

    /// Runs and expects success, recording the errors on failure so it's easy to see why. Returns the output.
    @discardableResult
    func succeed(_ arguments: String..., sourceLocation: SourceLocation = #_sourceLocation) async -> String {
        let result = await run(arguments)
        #expect(result.status == 0, "whatfeature \(arguments.joined(separator: " ")): \(result.errors)", sourceLocation: sourceLocation)
        return result.output
    }
}

private func withServer(_ test: @Sendable (Setup) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "whatfeature-commands-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteStore.inMemory()
    let admin = try await store.createAdminToken(name: "test", by: .system("test"))
    try await buildApplication(store: store).test(.live) { client in
        let port = try #require(client.port)
        try await test(Setup(
            url: "http://localhost:\(port)",
            token: admin.secret,
            settingsFile: directory.appending(path: "whatfeature/config.json")
        ))
    }
}

@Suite struct CommandTests {
    @Test func deleteAsksOnATerminal() async throws {
        try await withServer { cli in
            await cli.succeed("projects", "create", "demo")
            await cli.succeed("environments", "create", "dev")
            await cli.succeed("flags", "create", "beta", "--type", "boolean", "--variant", "on=true", "--variant", "off=false")

            // Anything but the flag's key is a no.
            let wrong = FakeTerminal(input: ["yes"], isInteractive: true)
            let refused = await cli.run("flags", "delete", "beta", terminal: wrong)
            #expect(refused.status != 0)
            #expect(refused.output.contains("Type the flag key to confirm:"))
            #expect(refused.errors.contains("Not deleted"))
            #expect(await cli.succeed("flags", "list").contains("beta"))

            let right = FakeTerminal(input: ["beta"], isInteractive: true)
            let deleted = await cli.run("flags", "delete", "beta", terminal: right)
            #expect(deleted.status == 0, "\(deleted.errors)")
            #expect(deleted.output.contains("Deleted beta."))
            #expect(await cli.succeed("flags", "list") == "No flags.\n")
        }
    }

    @Test func loginAsksForTheTokenAndLaterCommandsUseIt() async throws {
        try await withServer { cli in
            await cli.succeed("projects", "create", "demo")

            // No --token: it's read from the terminal, so it stays out of shell history.
            let terminal = FakeTerminal(input: [cli.token])
            let login = await cli.run("login", "--url", cli.url, "--project", "demo", environment: [:], terminal: terminal)
            #expect(login.status == 0, "\(login.errors)")
            #expect(login.output.hasPrefix("Admin token: Logged in to \(cli.url)"))

            let permissions = try FileManager.default.attributesOfItem(atPath: cli.settingsFile.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)

            // With no environment variables at all, commands use what login saved.
            let flags = await cli.run("flags", "list", environment: [:])
            #expect(flags.status == 0, "\(flags.errors)")
            #expect(flags.output == "No flags.\n")
        }
    }

    @Test func loginWithNoTokenFails() async throws {
        try await withServer { cli in
            let login = await cli.run("login", "--url", cli.url, environment: [:], terminal: FakeTerminal(input: []))
            #expect(login.status != 0)
            #expect(login.errors.contains("No token given."))
            #expect(!FileManager.default.fileExists(atPath: cli.settingsFile.path))
        }
    }

    /// A flag beats an environment variable, which beats what `login` saved.
    @Test func settingsComeFromTheFlagThenTheEnvironmentThenLogin() async throws {
        try await withServer { cli in
            await cli.succeed("projects", "create", "saved")
            await cli.run("login", "--url", cli.url, "--token", cli.token, "--project", "saved", environment: [:])

            func projectUsed(_ arguments: String..., environment: [String: String]) async -> String {
                // `flags list` on a project that doesn't exist names the project it looked for.
                let result = await cli.run(["flags", "list"] + arguments, environment: environment)
                return result.status == 0 ? "saved" : result.errors
            }
            #expect(await projectUsed(environment: [:]) == "saved")
            #expect(await projectUsed(environment: ["WHATFEATURE_PROJECT": "from-env"]).contains("'from-env'"))
            #expect(await projectUsed("-p", "from-flag", environment: ["WHATFEATURE_PROJECT": "from-env"]).contains("'from-flag'"))
        }
    }

    @Test func configSetReadsStandardInput() async throws {
        try await withServer { cli in
            await cli.succeed("projects", "create", "demo")
            await cli.succeed("environments", "create", "dev")
            await cli.succeed("flags", "create", "beta", "--type", "boolean", "--variant", "on=true", "--variant", "off=false")

            let config = #"{"enabled": true, "defaultResult": {"variant": "on"}}"#
            let set = await cli.run("config", "set", "beta", "-e", "dev", "-", terminal: FakeTerminal(input: [config]))
            #expect(set.status == 0, "\(set.errors)")
            #expect(await cli.succeed("evaluate", "beta", "-e", "dev", "--app-json") == #"{"key":"beta","reason":"STATIC","value":true,"variant":"on"}"# + "\n")
        }
    }

    @Test func badPortIsAnError() async throws {
        try await withServer { cli in
            let serve = await cli.run("serve", "--database", ":memory:", environment: ["PORT": "eighty"])
            #expect(serve.status != 0)
            #expect(serve.errors.contains("PORT must be a number"))
        }
    }
}
