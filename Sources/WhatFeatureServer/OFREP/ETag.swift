import Crypto
import Foundation
import WhatFeatureCore

/// ETags for the bulk endpoint.
///
/// The tag covers the environment's config version *and* the evaluation context. If only the config
/// were covered (as in flagd), a client that changed its context and kept its old ETag would get a
/// wrong `304`. Covering both means we can answer `304` without evaluating anything.
enum ETag {
    static func make(environment: EnvironmentID, version: Int, context: EvaluationContext) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let canonicalContext = try encoder.encode(context)

        var hasher = SHA256()
        hasher.update(data: Array("\(environment.rawValue)\n\(version)\n".utf8))
        hasher.update(data: canonicalContext)
        return "\"" + hasher.finalize().prefix(16).hexString + "\""
    }

    /// Whether an `If-None-Match` header matches `etag`. Handles `*`, lists, and weak (`W/`) tags.
    static func header(_ ifNoneMatch: String?, matches etag: String) -> Bool {
        guard let ifNoneMatch else { return false }
        return ifNoneMatch.split(separator: ",").contains { candidate in
            var candidate = candidate.trimmingCharacters(in: .whitespaces)
            if candidate == "*" { return true }
            if candidate.hasPrefix("W/") { candidate.removeFirst(2) }
            return candidate == etag
        }
    }
}
