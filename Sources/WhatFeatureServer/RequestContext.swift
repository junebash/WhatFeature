public import Hummingbird
public import WhatFeatureStorage

public struct WhatFeatureRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// Set by `EvaluationTokenMiddleware` once the request's token checks out.
    public var environment: EnvironmentID?
    /// Set by `AdminTokenMiddleware` for admin API requests.
    public var adminToken: Token?

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.environment = nil
        self.adminToken = nil
    }
}
