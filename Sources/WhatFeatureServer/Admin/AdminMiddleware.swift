import HTTPTypes
import Hummingbird
import WhatFeatureAPI
import WhatFeatureStorage

/// Lets admin tokens through. Unknown or revoked tokens get `401`; evaluation tokens get `403`.
struct AdminTokenMiddleware: RouterMiddleware {
    typealias Context = WhatFeatureRequestContext

    let store: SQLiteStore

    // `@concurrent`: see the note in EvaluationTokenMiddleware.
    func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let secret = request.headers.presentedToken,
              let token = try await store.authenticate(tokenHash: TokenHash.of(secret))
        else {
            return try .json(AdminErrorBody(error: "Missing, unknown or revoked token"), status: .unauthorized, headers: [.wwwAuthenticate: "Bearer"])
        }
        guard token.kind == .admin else {
            return try .json(AdminErrorBody(error: "The admin API needs an admin token, not an evaluation token"), status: .forbidden)
        }
        var context = context
        context.adminToken = token
        return try await next(request, context)
    }
}

/// Turns store and request errors into JSON: `{"error": "…", "issues": ["…"]}`.
struct AdminErrorMiddleware: RouterMiddleware {
    typealias Context = WhatFeatureRequestContext

    func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as StoreError {
            switch error {
            case .notFound(let message): return try .json(AdminErrorBody(error: message), status: .notFound)
            case .conflict(let message): return try .json(AdminErrorBody(error: message), status: .conflict)
            case .invalid(let issues): return try .json(AdminErrorBody(error: "Invalid", issues: issues), status: .badRequest)
            }
        } catch let error as AdminRequestError {
            return try .json(AdminErrorBody(error: error.message), status: .badRequest)
        }
    }
}

/// Something wrong with the request itself, like a body that isn't valid JSON. Always `400`.
struct AdminRequestError: Error {
    var message: String
}
