import Foundation
import HummingbirdTesting
import Subprocess
import Testing
import WhatFeatureServer
import WhatFeatureStorage

#if canImport(Darwin)
import System
#else
import SystemPackage
#endif

// The real `whatfeature` binary, run as a separate process against a real server, the way it's used from a
// terminal. `swift test` builds the binary; these tests find it in `.build/debug`.

private let cliURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // WhatFeatureIntegrationTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // package root
    .appending(path: ".build/debug/whatfeature")

private struct CLIResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// A server with one admin token, and a way to run the CLI against it. Each test gets an empty config
/// directory and a clean environment, so the machine's own `login` file or `WHATFEATURE_*` variables can't leak in.
private struct Harness: Sendable {
    var url: String
    var token: String
    var configHome: URL

    /// The settings every command needs, as environment variables, unless `connected` is false.
    func environment(connected: Bool = true, project: String? = "demo") -> [String: String] {
        var environment = [
            "HOME": configHome.path,
            "XDG_CONFIG_HOME": configHome.path,
            // The Keychain could show a dialog nobody answers. The file path is what's tested here.
            "WHATFEATURE_KEYCHAIN": "off",
            "PATH": "/usr/bin:/bin",
        ]
        if let libraryPath = ProcessInfo.processInfo.environment["LD_LIBRARY_PATH"] {
            environment["LD_LIBRARY_PATH"] = libraryPath
        }
        if connected {
            environment["WHATFEATURE_URL"] = url
            environment["WHATFEATURE_TOKEN"] = token
            if let project { environment["WHATFEATURE_PROJECT"] = project }
        }
        return environment
    }

    @discardableResult
    func run(_ arguments: String..., environment: [String: String]? = nil, input: String? = nil) async throws -> CLIResult {
        try await runProcess(arguments, environment: environment ?? self.environment(), input: input)
    }

    /// Runs and expects success, recording the output on failure so it's easy to see why.
    @discardableResult
    func succeed(_ arguments: String..., input: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        let result = try await runProcess(arguments, environment: environment(), input: input)
        #expect(
            result.status == 0,
            "whatfeature \(arguments.joined(separator: " ")) exited \(result.status): \(result.stderr)",
            sourceLocation: sourceLocation
        )
        return result.stdout
    }
}

private func withCLI(_ test: @Sendable (Harness) async throws -> Void) async throws {
    try #require(
        FileManager.default.isExecutableFile(atPath: cliURL.path),
        "Expected the CLI at \(cliURL.path). Run `swift build` first if it's missing."
    )
    let configHome = FileManager.default.temporaryDirectory.appending(path: "whatfeature-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: configHome) }

    let store = try SQLiteStore.inMemory()
    let admin = try await store.createAdminToken(name: "CLI test", by: .system("test"))
    try await buildApplication(store: store).test(.live) { client in
        let port = try #require(client.port)
        // "localhost", not 127.0.0.1: see the note in AdminClientTests.
        try await test(Harness(url: "http://localhost:\(port)", token: admin.secret, configHome: configHome))
    }
}

/// Runs the CLI with swift-subprocess, which waits for the process and reads its output asynchronously,
/// so no thread is blocked while it runs.
private func runProcess(_ arguments: [String], environment: [String: String], input: String?) async throws -> CLIResult {
    // `Subprocess.Environment`, because Hummingbird has an `Environment` too.
    let environment = Subprocess.Environment.custom(
        Dictionary(uniqueKeysWithValues: environment.map { (Subprocess.Environment.Key(stringLiteral: $0.key), $0.value) })
    )
    // With no input, stdin is /dev/null: not a terminal, like a script.
    if let input {
        return try await runCLI(environment: environment, arguments: arguments, input: .string(input))
    }
    return try await runCLI(environment: environment, arguments: arguments, input: .none)
}

private func runCLI(environment: Subprocess.Environment, arguments: [String], input: some InputProtocol) async throws -> CLIResult {
    let limit = 1 << 20
    let result = try await Subprocess.run(
        .path(FilePath(cliURL.path)),
        arguments: Arguments(arguments),
        environment: environment,
        input: input,
        output: .string(limit: limit),
        error: .string(limit: limit)
    )
    let status: Int32 = switch result.terminationStatus {
    case .exited(let code): code
    case .signaled(let signal): 128 + signal
    }
    return CLIResult(status: status, stdout: result.standardOutput, stderr: result.standardError)
}

@Suite struct CLITests {
    @Test func loginSavesSettingsForLaterCommands() async throws {
        try await withCLI { cli in
            // `login --project` checks the project exists.
            try await cli.succeed("projects", "create", "demo")

            let login = try await cli.run(
                "login", "--url", cli.url, "--token", cli.token, "--project", "demo",
                environment: cli.environment(connected: false)
            )
            #expect(login.status == 0, "\(login.stderr)")
            #expect(login.stdout.contains("Logged in to \(cli.url) as admin token \"CLI test\""))
            #expect(login.stdout.contains("Default project: demo"))

            // The token is saved for later commands, in a file only its owner can read.
            let file = cli.configHome.appending(path: "whatfeature/config.json")
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)

            let whoami = try await cli.run("whoami", environment: cli.environment(connected: false))
            #expect(whoami.status == 0, "\(whoami.stderr)")
            #expect(whoami.stdout.contains("\(cli.url) as admin token \"CLI test\""))

            let logout = try await cli.run("logout", environment: cli.environment(connected: false))
            #expect(logout.stdout.contains("Removed"))
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func managesAFlagFromStartToFinish() async throws {
        try await withCLI { cli in
            try await cli.succeed("projects", "create", "demo", "--name", "Demo")
            try await cli.succeed("environments", "create", "dev")
            try await cli.succeed("flags", "create", "beta", "--type", "boolean", "--variant", "on=true", "--variant", "off=false")

            // New flags start disabled: apps get their own defaults.
            #expect(try await cli.succeed("evaluate", "beta", "-e", "dev", "--app-json") == #"{"key":"beta","reason":"DISABLED"}"# + "\n")

            try await cli.succeed("config", "serve", "beta", "on", "-e", "dev")
            #expect(
                try await cli.succeed("evaluate", "beta", "-e", "dev", "--targeting-key", "june", "--app-json")
                    == #"{"key":"beta","reason":"STATIC","value":true,"variant":"on"}"# + "\n"
            )

            let summary = try await cli.succeed("evaluate", "beta", "-e", "dev")
            #expect(summary.contains("on = true"))
            #expect(summary.contains("Reason: STATIC"))

            try await cli.succeed("config", "rollout", "beta", "on=10", "off=90", "-e", "dev")
            let all = try await cli.succeed("evaluate", "--all", "-e", "dev", "--targeting-key", "june", "--app-json")
            #expect(all.hasPrefix(#"{"flags":[{"key":"beta","reason":"SPLIT""#))

            try await cli.succeed("config", "disable", "beta", "-e", "dev")
            #expect(try await cli.succeed("evaluate", "beta", "-e", "dev", "--app-json") == #"{"key":"beta","reason":"DISABLED"}"# + "\n")

            // Delete asks on a terminal. With no terminal it refuses, even if the right answer is piped in,
            // so a script has to say `--yes` on purpose.
            let refused = try await cli.run("flags", "delete", "beta", input: "beta\n")
            #expect(refused.status != 0)
            #expect(refused.stderr.contains("Not deleted"))
            try await cli.succeed("flags", "delete", "beta", "--yes")
            #expect(try await cli.succeed("flags", "list") == "No flags.\n")

            // Every change is in the audit log, under the CLI's token.
            let audit = try await cli.succeed("audit", "--json")
            #expect(audit.contains("flag.delete"))
            #expect(audit.contains("flagConfig.update"))
        }
    }

    @Test func failuresExitNonZeroWithAMessage() async throws {
        try await withCLI { cli in
            try await cli.succeed("projects", "create", "demo")
            try await cli.succeed("environments", "create", "dev")

            let missing = try await cli.run("evaluate", "nope", "-e", "dev")
            #expect(missing.status != 0)
            #expect(missing.stderr.contains("nope"))

            var badToken = cli.environment()
            badToken["WHATFEATURE_TOKEN"] = "wf_admin_wrong"
            let unauthorized = try await cli.run("flags", "list", environment: badToken)
            #expect(unauthorized.status != 0)
            #expect(unauthorized.stderr.contains("401"))

            let noServer = try await cli.run("flags", "list", environment: cli.environment(connected: false))
            #expect(noServer.status != 0)
        }
    }
}
