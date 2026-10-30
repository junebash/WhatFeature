import Testing
import WhatFeatureCore

@Suite struct SemanticVersionTests {
    @Test(arguments: [
        ("1.2.3", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("v1.2.3", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("2.1", SemanticVersion(major: 2, minor: 1)),
        ("7", SemanticVersion(major: 7)),
        ("1.0.0-beta.2", SemanticVersion(major: 1, prerelease: ["beta", "2"])),
        ("1.0.0+build.5", SemanticVersion(major: 1)),
        ("1.0.0-rc.1+build.5", SemanticVersion(major: 1, prerelease: ["rc", "1"])),
    ])
    func parses(_ string: String, _ expected: SemanticVersion) {
        #expect(SemanticVersion(string) == expected)
    }

    @Test(arguments: ["", "v", "1.", "1.2.3.4", "a.b.c", "1.0.0-", "1.0.0-beta..1", "1.0.0-01", "-1.0.0", "1.0.0-be$ta"])
    func rejects(_ string: String) {
        #expect(SemanticVersion(string) == nil)
    }

    /// The precedence example from semver.org, plus the case string comparison gets wrong.
    @Test func ordersVersions() throws {
        let ordered = try [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
            "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "2.0.0", "9.0.0", "10.0.0",
        ].map { try #require(SemanticVersion($0)) }

        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(lower < higher, "\(lower) should be before \(higher)")
            #expect(!(higher < lower))
        }
    }

    @Test func treatsHyphenIdentifierAsAlphanumeric() throws {
        // "-1" is not the number -1, so it sorts after any numeric identifier.
        let numeric = try #require(SemanticVersion("1.0.0-5"))
        let hyphenated = try #require(SemanticVersion("1.0.0--1"))
        #expect(numeric < hyphenated)
    }

    @Test func treatsMissingPartsAsZero() {
        #expect(SemanticVersion("2.1") == SemanticVersion("2.1.0"))
    }

    @Test func roundTripsAsString() throws {
        let version = try #require(SemanticVersion("3.0.0-beta.2"))
        #expect(try roundTrip(version) == version)
        #expect(version.description == "3.0.0-beta.2")
    }
}
