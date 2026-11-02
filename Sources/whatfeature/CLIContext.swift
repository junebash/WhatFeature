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
    /// Where `login` keeps the token. `nil` keeps it in the settings file: the default off macOS, and in tests.
    var keychain: Keychain? = nil

    @TaskLocal static var current: CLIContext = .live

    /// The real world. This is the only place the CLI uses process-wide globals.
    static var live: CLIContext {
        let environment = ProcessInfo.processInfo.environment
        let settingsFile = settingsFile(environment: environment, home: FileManager.default.homeDirectoryForCurrentUser)
        var context = CLIContext(
            environment: environment,
            settingsFile: settingsFile,
            terminal: StandardTerminal(threadPool: .singleton),
            httpClient: .shared,
            threadPool: .singleton
        )
        #if os(macOS)
        // `off` is for Macs where nobody can answer a Keychain dialog (CI, tests): the Keychain can show one and
        // wait for it, e.g. when there's no login keychain.
        if environment["WHATFEATURE_KEYCHAIN"] != "off" {
            context.keychain = Keychain(account: settingsFile.path)
        }
        #endif
        return context
    }

    /// `$XDG_CONFIG_HOME/whatfeature/config.json`, else `~/.config/whatfeature/config.json`.
    static func settingsFile(environment: [String: String], home: URL) -> URL {
        let base = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".config")
        return base.appending(path: "whatfeature/config.json")
    }
}

/// Standard input, output and error.
protocol Terminal: Sendable {
    /// Writes to standard output.
    func write(_ text: String) async throws
    /// Writes to standard error.
    func writeError(_ text: String) async throws
    /// One line of standard input, without its newline, or `nil` at the end of input.
    func readLine() async throws -> String?
    /// All of standard input.
    func readAll() async throws -> Data
    /// Whether standard input is a terminal a person can answer prompts on.
    var isInteractive: Bool { get }
}

/// The process's own standard input and output. Reads and writes happen on a thread pool, so waiting for
/// someone to type, or for a slow reader of our output (`whatfeature audit --json | less`), never blocks Swift
/// concurrency's shared threads.
struct StandardTerminal: Terminal {
    var threadPool: NIOThreadPool

    func write(_ text: String) async throws {
        try await Self.write(text, to: .standardOutput, threadPool: threadPool)
    }

    func writeError(_ text: String) async throws {
        try await Self.write(text, to: .standardError, threadPool: threadPool)
    }

    private static func write(_ text: String, to handle: FileHandle, threadPool: NIOThreadPool) async throws {
        do {
            try await threadPool.runIfActive { try handle.write(contentsOf: Data(text.utf8)) }
        } catch where isBrokenPipe(error) {
            throw OutputClosed()
        }
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

/// Whoever was reading our output stopped, e.g. `whatfeature audit | head`. Not our failure: the command
/// stops quietly.
struct OutputClosed: Error {}

/// Whether a write failed because the reader closed the pipe (EPIPE), however deeply Foundation wrapped it.
func isBrokenPipe(_ error: any Error) -> Bool {
    var current: NSError? = error as NSError
    while let error = current {
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPIPE) { return true }
        current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}

/// Writes a line to standard output, through `CLIContext.current`. Use this instead of `print`.
func writeLine(_ text: String = "", terminator: String = "\n") async throws {
    try await CLIContext.current.terminal.write(text + terminator)
}
