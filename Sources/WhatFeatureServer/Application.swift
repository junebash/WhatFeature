public import Hummingbird
import Logging
import WhatFeatureAPI
public import WhatFeatureStorage

/// Builds the HTTP app. Kept separate from `main` so tests can run it in memory.
public func buildApplication(
    store: SQLiteStore,
    configuration: ApplicationConfiguration = .init(),
    adminRateLimit: RateLimit? = .adminDefault
) -> some ApplicationProtocol {
    let router = Router(context: WhatFeatureRequestContext.self)
    // Logs method and path only. Evaluation contexts are in the body, so they never reach the logs.
    router.middlewares.add(LogRequestsMiddleware(.info))

    router.get("health") { _, _ in "ok" }

    // Never rate limited: evaluation tokens are shared by every install. See "Rate limiting" in DESIGN.md.
    // CORS sits outside the token check, so preflights (which carry no token) pass and 401s are readable.
    // The admin API gets no CORS.
    let ofrep = router.group("ofrep/v1")
        .add(middleware: OFREPCORSMiddleware())
        .add(middleware: EvaluationTokenMiddleware(store: store))
    OFREPRoutes(store: store).register(on: ofrep)

    let admin = router.group(RouterPath(AdminPaths.prefix))
        .add(middleware: AdminErrorMiddleware())
        .add(middleware: AdminTokenMiddleware(store: store, rateLimiter: adminRateLimit.map { RateLimiter(limit: $0) }))
    AdminRoutes(store: store).register(on: admin)

    return Application(router: router, configuration: configuration)
}
