import Foundation
import Hummingbird
import NIOCore
import NIOFoundationCompat
import WhatFeatureCore
import WhatFeatureStorage

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

        let snapshot = try await store.snapshot(for: environment)
        let evaluation = OFREPEvaluation(result: snapshot.evaluate(flagKey: key, context: evaluationContext), in: snapshot)
        return try .json(evaluation, status: evaluation.status)
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

        return try .json(OFREPBulkResponse(snapshot.evaluateAll(context: evaluationContext), in: snapshot), status: .ok, headers: [.eTag: etag])
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
