import ArgumentParser
import Foundation
import WhatFeatureClient

/// Saved by `whatfeature login`, in `$XDG_CONFIG_HOME/whatfeature/config.json` (or `~/.config/…`), readable
/// only by you.
struct SavedSettings: Codable {
    var url: String?
    var token: String?
    var project: String?

    static var fileURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "whatfeature/config.json")
    }

    static func load() -> SavedSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return SavedSettings() }
        return (try? JSONDecoder().decode(SavedSettings.self, from: data)) ?? SavedSettings()
    }

    func save() throws {
        let fileManager = FileManager.default
        let directory = Self.fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        // Create with owner-only permissions *before* writing, so the token is never readable by others.
        if !fileManager.fileExists(atPath: Self.fileURL.path) {
            guard fileManager.createFile(atPath: Self.fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CLIError("Couldn't create \(Self.fileURL.path).")
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        try data.write(to: Self.fileURL)
    }
}

/// Where the server is and which admin token to use. Each comes from the flag, else the environment
/// variable, else what `whatfeature login` saved.
struct ConnectionOptions: ParsableArguments {
    @Option(help: "Server URL. Env: WHATFEATURE_URL. Default: what `login` saved, else http://127.0.0.1:8080.")
    var url: String?

    @Option(help: "Admin token. Env: WHATFEATURE_TOKEN. Default: what `login` saved.")
    var token: String?

    func makeClient() throws -> AdminClient {
        let saved = SavedSettings.load()
        let environment = ProcessInfo.processInfo.environment
        let urlString = url ?? environment["WHATFEATURE_URL"] ?? saved.url ?? "http://127.0.0.1:8080"
        guard let baseURL = URL(string: urlString), baseURL.scheme == "http" || baseURL.scheme == "https" else {
            throw ValidationError("'\(urlString)' isn't an http(s) URL.")
        }
        guard let token = token ?? environment["WHATFEATURE_TOKEN"] ?? saved.token else {
            throw ValidationError("No admin token. Run `whatfeature login`, or pass --token / set WHATFEATURE_TOKEN.")
        }
        return AdminClient(baseURL: baseURL, token: token)
    }
}

/// The project to work in: `--project`, else WHATFEATURE_PROJECT, else the one saved by `login --project`.
struct ProjectOption: ParsableArguments {
    @Option(name: [.short, .long], help: "Project key. Env: WHATFEATURE_PROJECT. Default: what `login --project` saved.")
    var project: String?

    func resolve() throws -> String {
        guard let key = project ?? ProcessInfo.processInfo.environment["WHATFEATURE_PROJECT"] ?? SavedSettings.load().project else {
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
