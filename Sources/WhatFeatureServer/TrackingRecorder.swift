public import Foundation
public import Logging
public import ServiceLifecycle
import Synchronization
import WhatFeatureCore
public import WhatFeatureStorage

/// Records who each OFREP request was for and what it served, in environments with tracking on (see "Tracking"
/// in DESIGN.md).
///
/// Requests only add to an in-memory buffer. `run` writes the buffer to the `TrackingStore` every few seconds and
/// applies each environment's retention and allowlist every hour. Evaluation never waits on the tracking database
/// and never fails because of it.
public final class TrackingRecorder: Service, Sendable {
    public struct Configuration: Sendable {
        public var flushInterval: Duration
        public var sweepInterval: Duration
        /// Requests held between flushes. Beyond this, requests aren't recorded, and the next flush logs how many.
        public var capacity: Int

        public init(flushInterval: Duration = .seconds(5), sweepInterval: Duration = .seconds(3_600), capacity: Int = 10_000) {
            self.flushInterval = flushInterval
            self.sweepInterval = sweepInterval
            self.capacity = capacity
        }
    }

    private let store: SQLiteStore
    /// For reading what's been recorded. Changes go through the recorder, so they also apply to the buffer.
    public let trackingStore: TrackingStore
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let logger: Logger
    private let buffer = Mutex(Buffer())

    private struct Buffer {
        var pending: [Sighting] = []
        var dropped = 0
    }

    /// - Parameters:
    ///   - store: Where each environment's `TrackingSettings` come from.
    ///   - now: The clock for the times recorded.
    public init(
        store: SQLiteStore,
        trackingStore: TrackingStore,
        configuration: Configuration = .init(),
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "WhatFeature.Tracking")
    ) {
        self.store = store
        self.trackingStore = trackingStore
        self.configuration = configuration
        self.now = now
        self.logger = logger
    }

    /// Buffers one request, if its environment has tracking on and the context has a targeting key. Keeps only the
    /// allowlisted attributes, and only resolved results: disabled flags and errors served nothing. `results` is empty
    /// for a `304`, which still counts as seeing the targeting key.
    func record(_ results: [EvaluationResult], context: EvaluationContext, environment: EnvironmentID, snapshot: EnvironmentSnapshot) async {
        guard let targetingKey = context.targetingKey else { return }
        let settings: TrackingSettings
        do {
            settings = try await store.trackingSettings(for: environment)
        } catch {
            logger.error("Couldn't read tracking settings", metadata: ["environment": "\(environment)", "error": "\(error)"])
            return
        }
        guard settings.enabled else { return }

        let served = results.compactMap { result -> Sighting.Served? in
            guard case .resolved(_, let variant, let reason, let matchedRule) = result.outcome,
                  let config = snapshot.entries[result.flagKey]?.config
            else { return nil }
            return Sighting.Served(flagKey: result.flagKey, variant: variant, reason: reason, matchedRule: matchedRule, configVersion: config.version)
        }
        let sighting = Sighting(
            environmentID: environment,
            targetingKey: targetingKey,
            attributes: context.attributes.filter { settings.attributes.contains($0.key) && $0.value != .null },
            time: now(),
            served: served
        )
        buffer.withLock { buffer in
            if buffer.pending.count < configuration.capacity {
                buffer.pending.append(sighting)
            } else {
                buffer.dropped += 1
            }
        }
    }

    /// Applies new settings right away, to what's stored and what's buffered (see `TrackingStore.enforce`).
    public func apply(_ settings: TrackingSettings, to environment: EnvironmentID) async throws {
        buffer.withLock { buffer in
            for index in buffer.pending.indices where buffer.pending[index].environmentID == environment {
                buffer.pending[index].attributes = buffer.pending[index].attributes.filter { settings.attributes.contains($0.key) }
            }
        }
        try await trackingStore.enforce([environment: settings])
    }

    /// Deletes everything stored or buffered for one targeting key. Returns whether there was anything.
    public func deleteContext(_ targetingKey: String, in environment: EnvironmentID) async throws -> Bool {
        let buffered = buffer.withLock { buffer in
            let count = buffer.pending.count
            buffer.pending.removeAll { $0.environmentID == environment && $0.targetingKey == targetingKey }
            return count != buffer.pending.count
        }
        let stored = try await trackingStore.deleteContext(targetingKey, in: environment)
        return buffered || stored
    }

    /// Writes everything buffered. A batch that fails to write is logged and lost.
    public func flush() async {
        let (batch, dropped) = buffer.withLock { buffer in
            defer { buffer = Buffer() }
            return (buffer.pending, buffer.dropped)
        }
        if dropped > 0 {
            logger.warning("Tracking buffer was full; requests weren't recorded", metadata: ["dropped": "\(dropped)"])
        }
        do {
            try await trackingStore.record(batch)
        } catch {
            logger.error("Couldn't write tracking records", metadata: ["count": "\(batch.count)", "error": "\(error)"])
        }
    }

    /// Deletes what each environment's settings no longer allow (see `TrackingStore.enforce`).
    public func sweep() async {
        do {
            try await trackingStore.enforce(try await store.trackingSettings())
        } catch {
            logger.error("Couldn't apply tracking retention", metadata: ["error": "\(error)"])
        }
    }

    /// Sweeps at startup, then flushes and sweeps on schedule until shutdown, and flushes once more on the way out.
    /// The server shuts down before this does, so requests it finishes while draining are still written.
    public func run() async throws {
        await sweep()
        var sinceSweep = Duration.zero
        while true {
            do {
                try await cancelWhenGracefulShutdown { try await Task.sleep(for: self.configuration.flushInterval) }
            } catch {
                break
            }
            await flush()
            sinceSweep += configuration.flushInterval
            if sinceSweep >= configuration.sweepInterval {
                await sweep()
                sinceSweep = .zero
            }
        }
        await flush()
    }
}
