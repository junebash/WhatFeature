import Foundation
import WhatFeatureCore

extension Flag {
    static func boolean(_ key: String = "new-onboarding", archived: Bool = false) -> Flag {
        Flag(
            key: key,
            type: .boolean,
            variants: ["on": true, "off": false],
            createdBy: "token-1",
            createdAt: Date(timeIntervalSince1970: 0),
            archivedAt: archived ? Date(timeIntervalSince1970: 1) : nil
        )
    }
}

extension EnvironmentSnapshot {
    static func single(_ flag: Flag, _ config: FlagConfig) -> EnvironmentSnapshot {
        EnvironmentSnapshot(version: 1, entries: [Entry(flag: flag, config: config)])
    }
}

func decode<T: Decodable>(_: T.Type, from json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}
