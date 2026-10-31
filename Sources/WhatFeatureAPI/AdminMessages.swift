public import Foundation
public import WhatFeatureCore
public import WhatFeatureStorage

// Request and response bodies for /admin/v1 that aren't simply a model type. Shared by the server and the
// client, so the two can't drift apart.

public struct CreateProjectRequest: Sendable, Codable {
    public var key: String
    public var name: String?

    public init(key: String, name: String? = nil) {
        self.key = key
        self.name = name
    }
}

public struct CreateEnvironmentRequest: Sendable, Codable {
    public var key: String
    public var name: String?

    public init(key: String, name: String? = nil) {
        self.key = key
        self.name = name
    }
}

public struct CreateFlagRequest: Sendable, Codable {
    public var key: String
    public var type: FlagType
    public var variants: [String: JSONValue]
    public var description: String?
    public var isExperiment: Bool?
    /// What the new (disabled) configs serve once enabled. Defaults to the first variant name in sorted order.
    public var defaultVariant: String?

    public init(
        key: String,
        type: FlagType,
        variants: [String: JSONValue],
        description: String? = nil,
        isExperiment: Bool? = nil,
        defaultVariant: String? = nil
    ) {
        self.key = key
        self.type = type
        self.variants = variants
        self.description = description
        self.isExperiment = isExperiment
        self.defaultVariant = defaultVariant
    }
}

/// A flag plus its config in every environment, keyed by environment key.
public struct FlagDetail: Sendable, Codable {
    public var flag: Flag
    public var configs: [String: FlagConfig]

    public init(flag: Flag, configs: [String: FlagConfig]) {
        self.flag = flag
        self.configs = configs
    }
}

public struct DryRunRequest: Sendable, Codable {
    public var context: EvaluationContext

    public init(context: EvaluationContext) {
        self.context = context
    }
}

/// Like an OFREP result, plus why: which rule matched (`nil` means the default) and which config version
/// was used.
public struct DryRunResult: Sendable, Codable, Hashable {
    public var key: String
    public var reason: Reason
    public var value: JSONValue?
    public var variant: String?
    public var matchedRule: Int?
    public var errorCode: EvaluationErrorCode?
    public var errorDetails: String?
    public var configVersion: Int

    public init(_ result: EvaluationResult, configVersion: Int) {
        key = result.flagKey
        reason = result.reason
        self.configVersion = configVersion
        switch result.outcome {
        case .resolved(let value, let variant, _, let matchedRule):
            self.value = value
            self.variant = variant
            self.matchedRule = matchedRule
        case .disabled:
            break
        case .error(let code, let details):
            errorCode = code
            errorDetails = details
        }
    }
}

public struct CreateTokenRequest: Sendable, Codable {
    public var name: String
    public var kind: Token.Kind
    /// Project and environment keys. Required for evaluation tokens; not allowed for admin tokens.
    public var project: String?
    public var environment: String?

    public init(name: String, kind: Token.Kind, project: String? = nil, environment: String? = nil) {
        self.name = name
        self.kind = kind
        self.project = project
        self.environment = environment
    }
}

public struct CreatedTokenResponse: Sendable, Codable {
    public var token: Token
    /// Shown only in this response.
    public var secret: String

    public init(token: Token, secret: String) {
        self.token = token
        self.secret = secret
    }
}

/// An audit entry with `before` and `after` as JSON rather than strings of JSON.
public struct AuditEntryResponse: Sendable, Codable, Hashable {
    public var id: Int64
    public var timestamp: Date
    public var actor: String
    public var action: String
    public var projectID: ProjectID?
    public var environmentID: EnvironmentID?
    public var flagKey: String?
    public var before: JSONValue?
    public var after: JSONValue?

    public init(_ entry: AuditEntry) {
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

/// The body of every admin API error: `{"error": "…", "issues": ["…"]}`.
public struct AdminErrorBody: Sendable, Codable, Hashable {
    public var error: String
    public var issues: [String]?

    public init(error: String, issues: [String]? = nil) {
        self.error = error
        self.issues = issues
    }
}
