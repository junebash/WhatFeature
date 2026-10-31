import ArgumentParser
import Foundation
import NIOPosix
import WhatFeatureClient

/// Saved by `whatfeature login`, in `CLIContext.settingsFile` (`~/.config/whatfeature/config.json` by default),
/// readable only by you.
struct SavedSettings: Codable {
    var url: String?
    var token: String?
    var project: String?
}

extension CLIContext {
    /// What `login` saved, or empty settings if there's no file (or it can't be read).
    func loadSettings() async -> SavedSettings {
        let file = settingsFile
        let data = try? await threadPool.runIfActive { try Data(contentsOf: file) }
        return data.flatMap { try? JSONDecoder().decode(SavedSettings.self, from: $0) } ?? SavedSettings()
    }

    func saveSettings(_ settings: SavedSettings) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        let file = settingsFile
        try await threadPool.runIfActive {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Create with owner-only permissions *before* writing, so the token is never readable by others.
            if !fileManager.fileExists(atPath: file.path) {
                guard fileManager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CLIError("Couldn't create \(file.path).")
                }
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try data.write(to: file)
        }
    }

    /// Deletes the saved settings. Returns `false` if there were none.
    func removeSettings() async throws -> Bool {
        let file = settingsFile
        return try await threadPool.runIfActive {
            guard FileManager.default.fileExists(atPath: file.path) else { return false }
            try FileManager.default.removeItem(at: file)
            return true
        }
    }
}

/// Where the server is and which admin token to use. Each comes from the flag, else the environment
/// variable, else what `whatfeature login` saved.
struct ConnectionOptions: ParsableArguments {
    @Option(help: "Server URL. Env: WHATFEATURE_URL. Default: what `login` saved, else http://127.0.0.1:8080.")
    var url: String?

    @Option(help: "Admin token. Env: WHATFEATURE_TOKEN. Default: what `login` saved.")
    var token: String?

    func makeClient() async throws -> AdminClient {
        let context = CLIContext.current
        let saved = await context.loadSettings()
        let urlString = url ?? context.environment["WHATFEATURE_URL"] ?? saved.url ?? "http://127.0.0.1:8080"
        guard let baseURL = URL(string: urlString), baseURL.scheme == "http" || baseURL.scheme == "https" else {
            throw ValidationError("'\(urlString)' isn't an http(s) URL.")
        }
        guard let token = token ?? context.environment["WHATFEATURE_TOKEN"] ?? saved.token else {
            throw ValidationError("No admin token. Run `whatfeature login`, or pass --token / set WHATFEATURE_TOKEN.")
        }
        return AdminClient(baseURL: baseURL, token: token, httpClient: context.httpClient)
    }
}

/// The project to work in: `--project`, else WHATFEATURE_PROJECT, else the one saved by `login --project`.
struct ProjectOption: ParsableArguments {
    @Option(name: [.short, .long], help: "Project key. Env: WHATFEATURE_PROJECT. Default: what `login --project` saved.")
    var project: String?

    func resolve() async throws -> String {
        let context = CLIContext.current
        if let key = project ?? context.environment["WHATFEATURE_PROJECT"] { return key }
        guard let key = await context.loadSettings().project else {
            throw ValidationError("Which project? Pass --project, set WHATFEATURE_PROJECT, or save one with `whatfeature login --project`.")
        }
        return key
    }
}

struct EnvironmentOption: ParsableArguments {
    @Option(name: [.short, .customLong("env"), .customLong("environment")], help: "Environment key, e.g. dev or prod.")
    var environment: String
}

/// Runs a client call, turning connection failures into a plain message.
func withServer<T>(_ client: AdminClient, _ work: (AdminClient) async throws -> T) async throws -> T {
    do {
        return try await work(client)
    } catch let error as AdminClientError {
        throw CLIError(error.description)
    } catch let error as DecodingError {
        throw CLIError("The server's answer wasn't what this CLI expected (is it a different version?): \(error)")
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        // Everything else comes from the network: refused connections, timeouts, TLS problems.
        throw CLIError("Couldn't reach \(client.baseURL.absoluteString). Is the server running? (\(error))")
    }
}

/// An error whose description is the whole message, so ArgumentParser prints just that.
struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
