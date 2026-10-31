import Foundation
import HTTPTypes
import Hummingbird
import Logging
import WhatFeatureStorage

/// Checks the evaluation token and records which environment it can read.
///
/// OFREP allows either `Authorization: Bearer <token>` or `X-API-Key: <token>`; both work.
/// A token over its rate limit gets `429` with a `Retry-After` date.
struct EvaluationTokenMiddleware: RouterMiddleware {
    typealias Context = WhatFeatureRequestContext

    let store: any EvaluationStore
    let rateLimiter: RateLimiter?

    // `next` has to be spelled `@concurrent`: Hummingbird doesn't use NonisolatedNonsendingByDefault, so
    // its protocol's plain `async` closure means `@concurrent`, while in this module it would mean
    // `nonisolated(nonsending)`.
    func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        let tokenHash = request.headers.presentedToken.map(TokenHash.of)
        guard let tokenHash, let environment = try await store.environment(forTokenHash: tokenHash) else {
            return Response(status: .unauthorized, headers: [.wwwAuthenticate: "Bearer"])
        }
        if let wait = rateLimiter?.take(tokenHash) {
            context.logger.notice("Evaluation token over its rate limit", metadata: ["environment": "\(environment)"])
            return Response(status: .tooManyRequests, headers: [.retryAfter: Self.retryAfter(wait, from: .now)])
        }
        var context = context
        context.environment = environment
        return try await next(request, context)
    }
}

extension EvaluationTokenMiddleware {
    /// OFREP's spec gives `Retry-After` as an ISO 8601 date (e.g. `2024-02-07T12:00:00Z`), not the usual
    /// HTTP forms, and `swift-ofrep` fails to read plain seconds. Rounded up to the next whole second.
    static func retryAfter(_ wait: Duration, from now: Date) -> String {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 + wait.seconds).rounded(.up)).formatted(.iso8601)
    }
}

extension HTTPField.Name {
    static let apiKey = Self("X-API-Key")!
}

extension HTTPFields {
    /// `Authorization: Bearer <token>`, or else `X-API-Key: <token>`.
    var presentedToken: String? {
        if let authorization = self[.authorization] {
            let parts = authorization.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return String(parts[1])
            }
        }
        return self[.apiKey]
    }
}
