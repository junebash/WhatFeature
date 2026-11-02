import HTTPTypes
import Hummingbird

/// CORS for the OFREP endpoints, so browser apps can call them directly. Any origin: evaluation tokens are
/// public. See "Browsers (CORS)" in DESIGN.md.
///
/// Not Hummingbird's `CORSMiddleware`: it sends `Access-Control-Expose-Headers` only on preflights, but the
/// browser reads it from the actual response, so `ETag` would stay hidden.
struct OFREPCORSMiddleware: RouterMiddleware {
    typealias Context = WhatFeatureRequestContext

    // `@concurrent`: see the note in EvaluationTokenMiddleware.
    func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard request.headers[.origin] != nil else { return try await next(request, context) }
        if request.method == .options {
            return Response(status: .noContent, headers: [
                .accessControlAllowOrigin: "*",
                .accessControlAllowMethods: "POST",
                .accessControlAllowHeaders: "Authorization, X-API-Key, Content-Type, If-None-Match",
                .accessControlMaxAge: "86400",
            ])
        }
        var response = try await next(request, context)
        response.headers[.accessControlAllowOrigin] = "*"
        response.headers[.accessControlExposeHeaders] = "ETag"
        return response
    }
}
