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
struct OFREPEvaluation: Encodable {
    var result: EvaluationResult

    private enum CodingKeys: String, CodingKey {
        case key, value, variant, reason, errorCode, errorDetails
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
    }
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
