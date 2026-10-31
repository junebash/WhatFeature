public import Hummingbird
import Logging
public import WhatFeatureStorage

/// Builds the HTTP app. Kept separate from `main` so tests can run it in memory.
public func buildApplication(
    store: SQLiteStore,
    configuration: ApplicationConfiguration = .init()
) -> some ApplicationProtocol {
    let router = Router(context: WhatFeatureRequestContext.self)
    // Logs method and path only. Evaluation contexts are in the body, so they never reach the logs.
    router.middlewares.add(LogRequestsMiddleware(.info))

    router.get("health") { _, _ in "ok" }

    let ofrep = router.group("ofrep/v1").add(middleware: EvaluationTokenMiddleware(store: store))
    OFREPRoutes(store: store).register(on: ofrep)

    let admin = router.group("admin/v1")
        .add(middleware: AdminErrorMiddleware())
        .add(middleware: AdminTokenMiddleware(store: store))
    AdminRoutes(store: store).register(on: admin)

    return Application(router: router, configuration: configuration)
}
