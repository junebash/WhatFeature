import WhatFeatureCore

// The JSON shapes from OFREP's OpenAPI spec (service/openapi.yaml in open-feature/protocol).
// Written by hand rather than generated: the spec's allOf/oneOf nesting generates awkward types,
// and there are only two endpoints.

/// Body of both evaluation requests.
struct OFREPRequest: Decodable {
    var context: EvaluationContext
}

/// One flag's result. Three shapes:
/// - success: `key`, `value`, `variant`, `reason`
/// - disabled: `key`, `reason: DISABLED`, and no `value` (OFREP's "codeDefaultFlag": the app uses its own default)
/// - failure: `key`, `errorCode`, `errorDetails`
///
/// Any of them can also carry `metadata` about the flag (see `OFREPFlagMetadata`).
struct OFREPEvaluation: Encodable {
    var result: EvaluationResult
    /// `nil` when the flag doesn't exist.
    var flag: Flag?

    private enum CodingKeys: String, CodingKey {
        case key, value, variant, reason, errorCode, errorDetails, metadata
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result.flagKey, forKey: .key)
        switch result.outcome {
        case .resolved(let value, let variant, let reason, _):
            try container.encode(value, forKey: .value)
            try container.encode(variant, forKey: .variant)
            try container.encode(reason, forKey: .reason)
        case .disabled:
            try container.encode(Reason.disabled, forKey: .reason)
        case .error(let code, let details):
            try container.encode(code, forKey: .errorCode)
            try container.encode(details, forKey: .errorDetails)
        }
        if let metadata = flag.map(OFREPFlagMetadata.init), !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
    }
}

/// OFREP's flag `metadata`: a flat object of strings, numbers and booleans. OpenFeature SDKs hand it to
/// hooks as flag metadata, e.g. so an exposure-logging hook can tell experiments apart.
///
/// Keys are only sent when they say something, so most flags have no `metadata` at all.
struct OFREPFlagMetadata: Encodable {
    /// `true` for flags marked as experiments (A/B tests). Left out otherwise.
    var experiment: Bool?

    init(flag: Flag) {
        experiment = flag.isExperiment ? true : nil
    }

    var isEmpty: Bool { experiment == nil }
}

struct OFREPBulkResponse: Encodable {
    var flags: [OFREPEvaluation]
}

/// A failure that isn't about one particular flag, e.g. an unreadable request body.
/// `key` is set for single-flag requests, which OFREP requires.
struct OFREPRequestFailure: Error, Encodable {
    var key: String?
    var errorCode: EvaluationErrorCode
    var errorDetails: String
}
