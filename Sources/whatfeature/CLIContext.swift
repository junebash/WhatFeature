import AsyncHTTPClient
import Foundation
import NIOPosix

/// Everything the CLI takes from the outside world: environment variables, where `login` saves settings, the
/// terminal, the HTTP client, and threads for blocking work.
///
/// Commands read it from `CLIContext.current` rather than reaching for `ProcessInfo`, `FileManager`, standard
/// input and output, or `HTTPClient.shared` themselves. ArgumentParser builds the command structs, so there's
/// nowhere to pass these as parameters; a task-local is the way in. `main` uses `.live`; tests run commands
/// inside `CLIContext.$current.withValue(…)` with their own, so tests running at the same time can't see each
/// other's settings.
struct CLIContext: Sendable {
    /// Environment variables, e.g. `WHATFEATURE_URL`.
    var environment: [String: String]
    /// Where `whatfeature login` saves the URL, token and default project.
    var settingsFile: URL
    var terminal: any Terminal
    var httpClient: HTTPClient
    /// Runs blocking calls (file reads and writes, reading standard input) off Swift concurrency's shared threads.
    var threadPool: NIOThreadPool

    @TaskLocal static var current: CLIContext = .live

    /// The real world. This is the only place the CLI uses process-wide globals.
    static var live: CLIContext {
        let environment = ProcessInfo.processInfo.environment
        return CLIContext(
            environment: environment,
            settingsFile: settingsFile(environment: environment, home: FileManager.default.homeDirectoryForCurrentUser),
            terminal: StandardTerminal(threadPool: .singleton),
            httpClient: .shared,
            threadPool: .singleton
        )
    }

    /// `$XDG_CONFIG_HOME/whatfeature/config.json`, else `~/.config/whatfeature/config.json`.
    static func settingsFile(environment: [String: String], home: URL) -> URL {
        let base = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".config")
        return base.appending(path: "whatfeature/config.json")
    }
}

/// Standard input, output and error.
protocol Terminal: Sendable {
    /// Writes to standard output. Synchronous, like `print`.
    func write(_ text: String)
    /// Writes to standard error.
    func writeError(_ text: String)
    /// One line of standard input, without its newline, or `nil` at the end of input.
    func readLine() async throws -> String?
    /// All of standard input.
    func readAll() async throws -> Data
    /// Whether standard input is a terminal a person can answer prompts on.
    var isInteractive: Bool { get }
}

/// The process's own standard input and output. Reads happen on a thread pool, so waiting for someone to type
/// never blocks Swift concurrency's shared threads.
struct StandardTerminal: Terminal {
    var threadPool: NIOThreadPool

    func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    func readLine() async throws -> String? {
        try await threadPool.runIfActive { Swift.readLine() }
    }

    func readAll() async throws -> Data {
        try await threadPool.runIfActive { FileHandle.standardInput.readDataToEndOfFile() }
    }

    var isInteractive: Bool {
        isatty(STDIN_FILENO) != 0
    }
}

/// Writes a line to standard output, through `CLIContext.current`. Use this instead of `print`.
func writeLine(_ text: String = "", terminator: String = "\n") {
    CLIContext.current.terminal.write(text + terminator)
}
