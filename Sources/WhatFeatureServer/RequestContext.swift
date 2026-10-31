public import Hummingbird

public struct WhatFeatureRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// Set by `EvaluationTokenMiddleware` once the request's token checks out.
    public var environment: EnvironmentID?

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.environment = nil
    }
}
