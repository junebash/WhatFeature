/// A version like `2.1.0` or `3.0.0-beta.2`, compared the way semver.org says.
///
/// Parsing is a little more forgiving than strict semver, because app versions often aren't strict:
/// - a leading `v` is allowed (`v2.1.0`)
/// - missing minor or patch numbers count as zero (`2.1` is `2.1.0`)
/// - build metadata (`+build.5`) is ignored
public struct SemanticVersion: Sendable, Hashable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Pre-release identifiers, e.g. `["beta", "2"]` for `-beta.2`. Empty for a release.
    public var prerelease: [String]

    public init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ string: String) {
        var rest = Substring(string)
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }

        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let identifiers = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy(Self.isValidPrereleaseIdentifier) else { return nil }
            prerelease = identifiers.map(String.init)
            rest = rest[..<dash]
        }

        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }

        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease)
    }

    private static func isValidPrereleaseIdentifier(_ identifier: Substring) -> Bool {
        guard !identifier.isEmpty,
              identifier.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" })
        else { return false }
        // Numeric identifiers can't have leading zeros. This keeps `==` and `<` consistent.
        let isNumeric = identifier.allSatisfy(\.isASCIIDigit)
        return !(isNumeric && identifier.count > 1 && identifier.first == "0")
    }
}

extension SemanticVersion: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A release is newer than any of its pre-releases: 1.0.0-beta < 1.0.0.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Self.numericValue(of: left), Self.numericValue(of: right)) {
            case let (left?, right?): return left < right
            case (.some, nil): return true  // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// `Int("-1")` is -1, but in semver `-1` is an alphanumeric identifier, so check digits first.
    private static func numericValue(of identifier: String) -> Int? {
        identifier.allSatisfy(\.isASCIIDigit) ? Int(identifier) : nil
    }
}

extension SemanticVersion: CustomStringConvertible {
    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }
}

extension SemanticVersion: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let version = SemanticVersion(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "'\(string)' is not a valid version")
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
