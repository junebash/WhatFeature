import Foundation
import Hummingbird
import NIOCore
import NIOFoundationCompat
import WhatFeatureCore

/// `POST /ofrep/v1/evaluate/flags/{key}` and `POST /ofrep/v1/evaluate/flags`.
struct OFREPRoutes {
    typealias Context = WhatFeatureRequestContext

    let store: any EvaluationStore

    /// Request bodies are just an evaluation context, so this is generous.
    static let maxBodySize = 64 * 1_024

    func register(on group: RouterGroup<Context>) {
        group.post("evaluate/flags/{key}", use: evaluateFlag)
        group.post("evaluate/flags", use: evaluateAll)
    }

    @Sendable func evaluateFlag(_ request: Request, context: Context) async throws -> Response {
        let key = try context.parameters.require("key")
        let environment = try context.requireEnvironment()

        let evaluationContext: EvaluationContext
        switch await readContext(from: request) {
        case .success(let value):
            evaluationContext = value
        case .failure(let failure):
            return try .json(failure.with(key: key), status: .badRequest)
        }

        let result = try await store.snapshot(for: environment).evaluate(flagKey: key, context: evaluationContext)
        let status: HTTPResponse.Status = switch result.outcome {
        case .resolved, .disabled: .ok
        case .error(.flagNotFound, _): .notFound
        case .error: .badRequest
        }
        return try .json(OFREPEvaluation(result: result), status: status)
    }

    @Sendable func evaluateAll(_ request: Request, context: Context) async throws -> Response {
        let environment = try context.requireEnvironment()

        let evaluationContext: EvaluationContext
        switch await readContext(from: request) {
        case .success(let value):
            evaluationContext = value
        case .failure(let failure):
            return try .json(failure, status: .badRequest)
        }

        let snapshot = try await store.snapshot(for: environment)
        let etag = try ETag.make(environment: environment, version: snapshot.version, context: evaluationContext)
        if ETag.header(request.headers[.ifNoneMatch], matches: etag) {
            return Response(status: .notModified, headers: [.eTag: etag])
        }

        let flags = snapshot.evaluateAll(context: evaluationContext).map(OFREPEvaluation.init)
        return try .json(OFREPBulkResponse(flags: flags), status: .ok, headers: [.eTag: etag])
    }

    /// Unreadable JSON is `PARSE_ERROR`. Valid JSON with a bad or missing context is `INVALID_CONTEXT`.
    private func readContext(from request: Request) async -> Result<EvaluationContext, OFREPRequestFailure> {
        let body: ByteBuffer
        do {
            body = try await request.body.collect(upTo: Self.maxBodySize)
        } catch {
            return .failure(OFREPRequestFailure(errorCode: .parseError, errorDetails: "Request body is too large"))
        }

        do {
            return .success(try JSONDecoder().decode(OFREPRequest.self, from: body).context)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
            return .failure(OFREPRequestFailure(errorCode: .parseError, errorDetails: "Request body is not valid JSON"))
        } catch let error as DecodingError {
            return .failure(OFREPRequestFailure(errorCode: .invalidContext, errorDetails: error.summary))
        } catch {
            return .failure(OFREPRequestFailure(errorCode: .parseError, errorDetails: "Couldn't read the request body"))
        }
    }
}

extension OFREPRequestFailure {
    func with(key: String) -> Self {
        var copy = self
        copy.key = key
        return copy
    }
}

extension WhatFeatureRequestContext {
    /// The middleware guarantees this is set; a missing value means a routing bug.
    func requireEnvironment() throws -> EnvironmentID {
        guard let environment else { throw HTTPError(.internalServerError) }
        return environment
    }
}

extension DecodingError {
    /// A short, client-safe description. Never includes context values.
    var summary: String {
        switch self {
        case .keyNotFound(let key, let context):
            "Missing '\((context.codingPath + [key]).dotPath)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath.isEmpty
                ? context.debugDescription
                : "'\(context.codingPath.dotPath)': \(context.debugDescription)"
        @unknown default:
            "Invalid request"
        }
    }
}

extension [any CodingKey] {
    var dotPath: String { map(\.stringValue).joined(separator: ".") }
}

extension Response {
    static func json(
        _ value: some Encodable,
        status: HTTPResponse.Status,
        headers: HTTPFields = [:]
    ) throws -> Response {
        var headers = headers
        headers[.contentType] = "application/json"
        let data = try JSONEncoder().encode(value)
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
    }
}
