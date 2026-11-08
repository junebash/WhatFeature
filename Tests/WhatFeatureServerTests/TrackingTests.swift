import Foundation
import HTTPTypes
import HummingbirdTesting
import Logging
import NIOCore
import ServiceLifecycle
import Synchronization
import Testing
import WhatFeatureCore
import WhatFeatureServer
import WhatFeatureStorage

private let token = "wf_eval_tracking"
private let me = AuditActor.system("test")

/// Project `demo`, environment `dev` with the token above:
/// - `greeting`: `hello` for US, else the default `hi`
/// - `half`: a 50/50 rollout
/// - `off-flag`: disabled
private struct Setup {
    let store: SQLiteStore
    let trackingStore: TrackingStore
    let recorder: TrackingRecorder
    let dev: EnvironmentID
    let clock = Clock()

    init(capacity: Int = 10_000) async throws {
        let seed = """
        {"projects": [{"key": "demo", "environments": [{"key": "dev", "evaluationTokens": ["\(token)"]}], "flags": [
          {"key": "greeting", "type": "string", "variants": {"hello": "Hello", "hi": "Hi"}, "configs": {"dev": {
            "enabled": true,
            "rules": [{"conditions": [{"attribute": "country", "operator": "equals", "value": "US"}], "result": {"variant": "hello"}}],
            "defaultResult": {"variant": "hi"}
          }}},
          {"key": "half", "type": "boolean", "variants": {"on": true, "off": false}, "configs": {"dev": {
            "enabled": true, "defaultResult": {"rollout": [{"variant": "on", "weight": 5000}, {"variant": "off", "weight": 5000}]}
          }}},
          {"key": "off-flag", "type": "boolean", "variants": {"on": true, "off": false}}
        ]}]}
        """
        store = try SQLiteStore.inMemory()
        try await store.load(try JSONDecoder().decode(Seed.self, from: Data(seed.utf8)))
        let project = try #require(try await store.project(key: "demo"))
        dev = try #require(try await store.environment(key: "dev", in: project.id)).id
        trackingStore = try TrackingStore.inMemory(now: clock.now)
        recorder = TrackingRecorder(
            store: store, trackingStore: trackingStore, configuration: .init(capacity: capacity), now: clock.now
        )
    }

    func enable(attributes: [String] = []) async throws {
        try await store.setTracking(TrackingSettings(enabled: true, attributes: attributes), environment: dev, by: me)
    }

    func advance(by seconds: TimeInterval) {
        clock.current.withLock { $0 += seconds }
    }

    var time: Date { clock.now() }

    /// The variant `half` serves to `targetingKey`, worked out the way rollouts do it.
    func halfVariant(for targetingKey: String) async throws -> String {
        let result = try await store.snapshot(for: dev).evaluate(flagKey: "half", context: EvaluationContext(targetingKey: targetingKey))
        guard case .resolved(_, let variant, _, _) = result.outcome else { throw CancellationError() }
        return variant
    }
}

private final class Clock: Sendable {
    let current = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

    var now: @Sendable () -> Date {
        { self.current.withLock { $0 } }
    }
}

@discardableResult
private func post(
    _ client: some TestClientProtocol,
    _ path: String,
    _ body: String,
    ifNoneMatch: String? = nil
) async throws -> (HTTPResponse.Status, String?) {
    var headers: HTTPFields = [.authorization: "Bearer \(token)"]
    if let ifNoneMatch { headers[.ifNoneMatch] = ifNoneMatch }
    return try await client.execute(uri: path, method: .post, headers: headers, body: ByteBuffer(string: body)) { response in
        (response.status, response.headers[.eTag])
    }
}

private let bulk = "/ofrep/v1/evaluate/flags"

@Suite struct TrackingTests {
    @Test func recordsNothingUntilTurnedOnThenTakesEffectImmediately() async throws {
        let setup = try await Setup()
        let app = buildApplication(store: setup.store, tracking: setup.recorder)
        try await app.test(.router) { client in
            try await post(client, bulk, #"{"context": {"targetingKey": "u1"}}"#)
            await setup.recorder.flush()
            #expect(try await setup.trackingStore.seenContexts(in: setup.dev).isEmpty)

            try await setup.enable()
            try await post(client, bulk, #"{"context": {"targetingKey": "u1"}}"#)
            await setup.recorder.flush()
            #expect(try await setup.trackingStore.seenContexts(in: setup.dev).map(\.targetingKey) == ["u1"])
        }
    }

    @Test func bulkRecordsAllowlistedAttributesAndResolvedFlagsOnly() async throws {
        let setup = try await Setup()
        try await setup.enable(attributes: ["appVersion", "platform"])
        let app = buildApplication(store: setup.store, tracking: setup.recorder)
        try await app.test(.router) { client in
            let (status, _) = try await post(
                client, bulk,
                #"{"context": {"targetingKey": "u1", "country": "US", "appVersion": "3.1", "platform": null, "email": "a@b.com"}}"#
            )
            #expect(status == .ok)
        }
        await setup.recorder.flush()

        let seen = try #require(try await setup.trackingStore.seenContext("u1", in: setup.dev))
        #expect(seen.attributes == ["appVersion": "3.1"], "Not allowlisted: country, email. Null: platform")
        #expect(seen.lastSeen == setup.time)

        let exposures = try await setup.trackingStore.exposures(in: setup.dev, targetingKey: "u1")
        #expect(exposures.map(\.flagKey) == ["greeting", "half"], "off-flag is disabled, so nothing was served")
        let greeting = try #require(exposures.first)
        #expect((greeting.variant, greeting.reason, greeting.matchedRule) == ("hello", .targetingMatch, 0))
        #expect(greeting.configVersion == (try await setup.store.config(flagKey: "greeting", in: setup.dev))?.version)
        #expect(exposures.last?.variant == (try await setup.halfVariant(for: "u1")))
        #expect(exposures.last?.reason == .split)
    }

    @Test func notModifiedCountsAsSeenButServesNothingNew() async throws {
        let setup = try await Setup()
        try await setup.enable()
        let app = buildApplication(store: setup.store, tracking: setup.recorder)
        try await app.test(.router) { client in
            let body = #"{"context": {"targetingKey": "u1"}}"#
            let (_, etag) = try await post(client, bulk, body)
            await setup.recorder.flush()
            let firstTime = setup.time

            setup.advance(by: 60)
            let (status, _) = try await post(client, bulk, body, ifNoneMatch: etag)
            #expect(status == .notModified)
            await setup.recorder.flush()

            #expect(try await setup.trackingStore.seenContext("u1", in: setup.dev)?.lastSeen == setup.time)
            let exposures = try await setup.trackingStore.exposures(in: setup.dev)
            #expect(exposures.map(\.lastServed) == [firstTime, firstTime])
        }
    }

    @Test func singleFlagRecordsOneExposureAndSkipsRequestsWithoutATargetingKey() async throws {
        let setup = try await Setup()
        try await setup.enable()
        let app = buildApplication(store: setup.store, tracking: setup.recorder)
        try await app.test(.router) { client in
            try await post(client, "\(bulk)/greeting", #"{"context": {"targetingKey": "u1", "country": "DE"}}"#)
            try await post(client, "\(bulk)/off-flag", #"{"context": {"targetingKey": "u2"}}"#)
            try await post(client, bulk, #"{"context": {"country": "US"}}"#)
        }
        await setup.recorder.flush()

        #expect(try await setup.trackingStore.seenContexts(in: setup.dev).map(\.targetingKey).sorted() == ["u1", "u2"])
        let exposures = try await setup.trackingStore.exposures(in: setup.dev)
        #expect(exposures.map { "\($0.targetingKey) \($0.flagKey) \($0.variant) \($0.reason.rawValue)" } == ["u1 greeting hi DEFAULT"])
    }

    @Test func aFullBufferDropsRequestsUntilTheNextFlush() async throws {
        let setup = try await Setup(capacity: 2)
        try await setup.enable()
        let app = buildApplication(store: setup.store, tracking: setup.recorder)
        try await app.test(.router) { client in
            for key in ["a", "b", "c"] {
                try await post(client, bulk, #"{"context": {"targetingKey": "\#(key)"}}"#)
            }
            await setup.recorder.flush()
            try await post(client, bulk, #"{"context": {"targetingKey": "d"}}"#)
            await setup.recorder.flush()
        }
        #expect(try await setup.trackingStore.seenContexts(in: setup.dev).map(\.targetingKey).sorted() == ["a", "b", "d"])
    }

    @Test func sweepAppliesTheCurrentAllowlist() async throws {
        let setup = try await Setup()
        try await setup.enable(attributes: ["appVersion", "platform"])
        let app = buildApplication(store: setup.store, tracking: setup.recorder)
        try await app.test(.router) { client in
            try await post(client, bulk, #"{"context": {"targetingKey": "u1", "appVersion": "3.1", "platform": "iOS"}}"#)
        }
        await setup.recorder.flush()

        try await setup.enable(attributes: ["platform"])
        await setup.recorder.sweep()
        #expect(try await setup.trackingStore.seenContext("u1", in: setup.dev)?.attributes == ["platform": "iOS"])
    }

    /// Requests buffered just before shutdown are still written.
    @Test func runFlushesOnGracefulShutdown() async throws {
        let setup = try await Setup()
        try await setup.enable()
        let recorder = TrackingRecorder(
            store: setup.store, trackingStore: setup.trackingStore, configuration: .init(flushInterval: .seconds(3_600))
        )
        let group = ServiceGroup(services: [recorder], logger: Logger(label: "test"))
        try await withThrowingTaskGroup { tasks in
            tasks.addTask { try await group.run() }
            let app = buildApplication(store: setup.store, tracking: recorder)
            try await app.test(.router) { client in
                try await post(client, bulk, #"{"context": {"targetingKey": "u1"}}"#)
            }
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
        #expect(try await setup.trackingStore.seenContexts(in: setup.dev).map(\.targetingKey) == ["u1"])
    }
}
