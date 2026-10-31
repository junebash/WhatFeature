import Foundation
import WhatFeatureCore
import WhatFeatureStorage

// Request and response bodies for /admin/v1 that aren't simply a model type.

struct CreateProjectRequest: Decodable {
    var key: String
    var name: String?
}

struct CreateEnvironmentRequest: Decodable {
    var key: String
    var name: String?
}

struct CreateFlagRequest: Decodable {
    var key: String
    var type: FlagType
    var variants: [String: JSONValue]
    var description: String?
    var isExperiment: Bool?
}

/// A flag plus its config in every environment, keyed by environment key.
struct FlagDetail: Encodable {
    var flag: Flag
    var configs: [String: FlagConfig]
}

struct DryRunRequest: Decodable {
    var context: EvaluationContext
}

/// Like an OFREP result, plus why: which rule matched (`nil` means the default) and which config version
/// was used.
struct DryRunResult: Encodable {
    var result: EvaluationResult
    var configVersion: Int

    private enum CodingKeys: String, CodingKey {
        case key, value, variant, reason, matchedRule, errorCode, errorDetails, configVersion
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result.flagKey, forKey: .key)
        try container.encode(result.reason, forKey: .reason)
        try container.encode(configVersion, forKey: .configVersion)
        switch result.outcome {
        case .resolved(let value, let variant, _, let matchedRule):
            try container.encode(value, forKey: .value)
            try container.encode(variant, forKey: .variant)
            try container.encodeIfPresent(matchedRule, forKey: .matchedRule)
        case .disabled:
            break
        case .error(let code, let details):
            try container.encode(code, forKey: .errorCode)
            try container.encode(details, forKey: .errorDetails)
        }
    }
}

struct CreateTokenRequest: Decodable {
    var name: String
    var kind: Token.Kind
    /// Project and environment keys. Required for evaluation tokens; not allowed for admin tokens.
    var project: String?
    var environment: String?
}

struct CreatedTokenResponse: Encodable {
    var token: Token
    /// Shown only in this response.
    var secret: String
}

/// An audit entry with `before` and `after` as JSON rather than strings of JSON.
struct AuditEntryResponse: Encodable {
    var id: Int64
    var timestamp: Date
    var actor: String
    var action: String
    var projectID: ProjectID?
    var environmentID: EnvironmentID?
    var flagKey: String?
    var before: JSONValue?
    var after: JSONValue?

    init(_ entry: AuditEntry) {
        func parse(_ json: String?) -> JSONValue? {
            json.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        }
        id = entry.id
        timestamp = entry.timestamp
        actor = entry.actor
        action = entry.action
        projectID = entry.projectID
        environmentID = entry.environmentID
        flagKey = entry.flagKey
        before = parse(entry.before)
        after = parse(entry.after)
    }
}
