import HTTPTypes
import Hummingbird
import WhatFeatureStorage

/// Checks the evaluation token and records which environment it can read.
///
/// OFREP allows either `Authorization: Bearer <token>` or `X-API-Key: <token>`; both work.
struct EvaluationTokenMiddleware: RouterMiddleware {
    typealias Context = WhatFeatureRequestContext

    let store: any EvaluationStore

    // `next` has to be spelled `@concurrent`: Hummingbird doesn't use NonisolatedNonsendingByDefault, so
    // its protocol's plain `async` closure means `@concurrent`, while in this module it would mean
    // `nonisolated(nonsending)`.
    func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let secret = request.headers.evaluationToken,
              let environment = try await store.environment(forTokenHash: TokenHash.of(secret))
        else {
            return Response(status: .unauthorized, headers: [.wwwAuthenticate: "Bearer"])
        }
        var context = context
        context.environment = environment
        return try await next(request, context)
    }
}

extension HTTPField.Name {
    static let apiKey = Self("X-API-Key")!
}

extension HTTPFields {
    var evaluationToken: String? {
        if let authorization = self[.authorization] {
            let parts = authorization.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return String(parts[1])
            }
        }
        return self[.apiKey]
    }
}
