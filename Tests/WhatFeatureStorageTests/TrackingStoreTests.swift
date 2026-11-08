import Foundation
import Testing
import WhatFeatureCore
import WhatFeatureStorage

private let dev = EnvironmentID("dev")
private let prod = EnvironmentID("prod")
private let start = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 86_400

private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

private func sighting(
    _ key: String,
    in environment: EnvironmentID = dev,
    at time: Date,
    attributes: [String: JSONValue] = [:],
    served: [Sighting.Served] = []
) -> Sighting {
    Sighting(environmentID: environment, targetingKey: key, attributes: attributes, time: time, served: served)
}

private func served(_ flag: String, _ variant: String, reason: Reason = .split, rule: Int? = nil, version: Int = 1) -> Sighting.Served {
    Sighting.Served(flagKey: flag, variant: variant, reason: reason, matchedRule: rule, configVersion: version)
}

@Suite struct TrackingStoreTests {
    @Test func batchesArrivingOutOfOrderKeepEarliestFirstAndLatestEverythingElse() async throws {
        let store = try TrackingStore.inMemory()
        try await store.record([
            sighting("device-1", at: at(100), attributes: ["appVersion": "3.1"], served: [served("beta", "on", reason: .split, version: 2)]),
        ])
        // Recorded later, but happened earlier and in between.
        try await store.record([
            sighting("device-1", at: at(50), attributes: ["appVersion": "3.0"], served: [served("beta", "on", reason: .static, version: 1)]),
            sighting("device-1", at: at(75), attributes: ["appVersion": "3.0.5"]),
        ])

        let seen = try #require(try await store.seenContext("device-1", in: dev))
        #expect(seen.firstSeen == at(50))
        #expect(seen.lastSeen == at(100))
        #expect(seen.attributes == ["appVersion": "3.1"])

        let exposures = try await store.exposures(in: dev)
        #expect(exposures.count == 1)
        let exposure = try #require(exposures.first)
        #expect((exposure.firstServed, exposure.lastServed) == (at(50), at(100)))
        #expect((exposure.reason, exposure.configVersion) == (.split, 2))
    }

    @Test func movingToAnotherVariantAddsAnExposure() async throws {
        let store = try TrackingStore.inMemory()
        try await store.record([
            sighting("device-1", at: at(0), served: [served("checkout", "control", rule: 0), served("beta", "off", reason: .static)]),
            sighting("device-1", at: at(10), served: [served("checkout", "control", rule: 0)]),
            sighting("device-1", at: at(20), served: [served("checkout", "test", rule: nil, version: 3)]),
        ])

        let checkout = try await store.exposures(in: dev, flagKey: "checkout")
        #expect(checkout.map(\.variant) == ["control", "test"])
        #expect(checkout.map(\.lastServed) == [at(10), at(20)])
        #expect(checkout.map(\.matchedRule) == [0, nil])
        #expect(try await store.exposures(in: dev, targetingKey: "device-1").count == 3)
    }

    @Test func environmentsAreSeparate() async throws {
        let store = try TrackingStore.inMemory()
        try await store.record([
            sighting("device-1", in: dev, at: at(0), served: [served("beta", "on")]),
            sighting("device-1", in: prod, at: at(5), served: [served("beta", "off")]),
        ])
        #expect(try await store.exposures(in: dev).map(\.variant) == ["on"])
        #expect(try await store.exposures(in: prod).map(\.variant) == ["off"])
        #expect(try await store.seenContext("device-1", in: dev)?.lastSeen == at(0))
    }

    @Test func listsMostRecentlySeenFirst() async throws {
        let store = try TrackingStore.inMemory()
        try await store.record([
            sighting("a", at: at(30)), sighting("b", at: at(10)), sighting("c", at: at(20)), sighting("d", in: prod, at: at(40)),
        ])
        #expect(try await store.seenContexts(in: dev).map(\.targetingKey) == ["a", "c", "b"])
        #expect(try await store.seenContexts(in: dev, since: at(20)).map(\.targetingKey) == ["a", "c"])
        #expect(try await store.seenContexts(in: dev, limit: 1).map(\.targetingKey) == ["a"])
    }

    @Test func deletingAContextRemovesItsExposuresAndNothingElse() async throws {
        let store = try TrackingStore.inMemory()
        try await store.record([
            sighting("device-1", in: dev, at: at(0), served: [served("beta", "on"), served("checkout", "test")]),
            sighting("device-1", in: prod, at: at(0), served: [served("beta", "on")]),
            sighting("device-2", in: dev, at: at(0), served: [served("beta", "off")]),
        ])

        #expect(try await store.deleteContext("device-1", in: dev))
        #expect(try await store.seenContext("device-1", in: dev) == nil)
        #expect(try await store.exposures(in: dev).map(\.targetingKey) == ["device-2"])
        #expect(try await store.exposures(in: prod).map(\.targetingKey) == ["device-1"])
        #expect(try await store.deleteContext("device-1", in: dev) == false)
    }

    @Test func enforceExpiresContextsByLastSeenPerEnvironment() async throws {
        let now = start.addingTimeInterval(30 * day)
        let store = try TrackingStore.inMemory(now: { now })
        try await store.record([
            // Seen on day 0 and again on day 25: the second visit keeps it.
            sighting("returning", at: at(0), served: [served("beta", "on")]),
            sighting("returning", at: at(25 * day)),
            sighting("exactly-30-days", at: at(0)),
            sighting("just-over", at: at(-1), served: [served("beta", "off")]),
            sighting("just-over", in: prod, at: at(-1)),
        ])

        try await store.enforce([dev: TrackingSettings(retentionDays: 30)])
        #expect(try await store.seenContexts(in: dev).map(\.targetingKey) == ["returning", "exactly-30-days"])
        #expect(try await store.exposures(in: dev).map(\.targetingKey) == ["returning"])
        #expect(try await store.seenContexts(in: prod).count == 1, "Environments without settings are left alone")

        try await store.enforce([prod: TrackingSettings(retentionDays: 31)])
        #expect(try await store.seenContexts(in: prod).count == 1)
    }

    @Test func enforceDropsAttributesNoLongerAllowed() async throws {
        let store = try TrackingStore.inMemory(now: { start })
        try await store.record([
            sighting("a", at: at(0), attributes: ["appVersion": "3.1", "platform": "iOS", "country": "DE"]),
            sighting("b", at: at(0), attributes: ["appVersion": "2.0"]),
            sighting("a", in: prod, at: at(0), attributes: ["appVersion": "3.1", "platform": "iOS"]),
        ])

        try await store.enforce([dev: TrackingSettings(attributes: ["appVersion", "platform"])])
        #expect(try await store.seenContext("a", in: dev)?.attributes == ["appVersion": "3.1", "platform": "iOS"])

        try await store.enforce([dev: TrackingSettings(attributes: ["platform"])])
        #expect(try await store.seenContext("a", in: dev)?.attributes == ["platform": "iOS"])
        #expect(try await store.seenContext("b", in: dev)?.attributes == [:])

        try await store.enforce([dev: TrackingSettings(attributes: [])])
        #expect(try await store.seenContext("a", in: dev)?.attributes == [:])
        #expect(try await store.seenContext("a", in: prod)?.attributes == ["appVersion": "3.1", "platform": "iOS"])
    }

    @Test func survivesReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "whatfeature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "tracking.sqlite").path

        do {
            let store = try TrackingStore(path: path)
            try await store.record([sighting("device-1", at: at(0), attributes: ["n": 1], served: [served("beta", "on")])])
        }
        let reopened = try TrackingStore(path: path)
        #expect(try await reopened.seenContext("device-1", in: dev)?.attributes == ["n": 1])
        #expect(try await reopened.exposures(in: dev).count == 1)
    }
}
