public import Hummingbird
import Logging
import WhatFeatureAPI
public import WhatFeatureStorage

/// Builds the HTTP app. Kept separate from `main` so tests can run it in memory.
public func buildApplication(
    store: SQLiteStore,
    configuration: ApplicationConfiguration = .init(),
    adminRateLimit: RateLimit? = .adminDefault,
    tracking: TrackingRecorder? = nil
) -> some ApplicationProtocol {
    let router = Router(context: WhatFeatureRequestContext.self)
    // Method and path only: evaluation contexts are in the body, and targeting keys in admin queries.
    router.middlewares.add(LogRequestPathsMiddleware())

    router.get("health") { _, _ in "ok" }

    // Never rate limited: evaluation tokens are shared by every install. See "Rate limiting" in DESIGN.md.
    // CORS sits outside the token check, so preflights (which carry no token) pass and 401s are readable.
    // The admin API gets no CORS.
    let ofrep = router.group("ofrep/v1")
        .add(middleware: OFREPCORSMiddleware())
        .add(middleware: EvaluationTokenMiddleware(store: store))
    OFREPRoutes(store: store, tracking: tracking).register(on: ofrep)

    let admin = router.group(RouterPath(AdminPaths.prefix))
        .add(middleware: AdminErrorMiddleware())
        .add(middleware: AdminTokenMiddleware(store: store, rateLimiter: adminRateLimit.map { RateLimiter(limit: $0) }))
    AdminRoutes(store: store, tracking: tracking).register(on: admin)

    return Application(router: router, configuration: configuration, services: tracking.map { [$0] } ?? [])
}

/// Like Hummingbird's `LogRequestsMiddleware`, but without the query string, which can hold targeting keys
/// (e.g. `…/tracking/context?targetingKey=…`).
struct LogRequestPathsMiddleware: RouterMiddleware {
    typealias Context = WhatFeatureRequestContext

    func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        context.logger.info(
            "Request",
            metadata: ["hb.request.path": .string(request.uri.path), "hb.request.method": .string(request.method.rawValue)]
        )
        return try await next(request, context)
    }
}
