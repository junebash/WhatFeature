import HTTPTypes
import Hummingbird

/// Serves the browser UI (the built `ui/` app) at `/ui/` from a folder. Only requests no route matched get here.
///
/// The page holds an admin token, so its responses carry a strict Content Security Policy: scripts, styles and
/// API calls only from this server, and no framing. The UI calls the admin API from the same origin, so the
/// admin API still needs no CORS.
struct WebUIMiddleware: RouterMiddleware {
    typealias Context = WhatFeatureRequestContext

    static let path = "/ui"

    let files: FileMiddleware<Context, LocalFileSystem>

    init(directory: String) {
        files = FileMiddleware(
            directory,
            urlBasePath: Self.path,
            cacheControl: CacheControl([
                // index.html names the current build's assets, so it's checked every time; the assets' names
                // change with their contents, so they're cached for good.
                (.textHtml, [.noCache]),
                (.textJavascript, [.public, .maxAge(31_536_000), .immutable]),
                (.textCss, [.public, .maxAge(31_536_000), .immutable]),
            ]),
            searchForIndexHtml: true
        )
    }

    // `@concurrent` like `next` (see EvaluationTokenMiddleware), because FileMiddleware's `handle` is too.
    @concurrent func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        var response = try await files.handle(request, context: context, next: next)
        if request.uri.path == Self.path || request.uri.path.hasPrefix(Self.path + "/") {
            response.headers[.contentSecurityPolicy] =
                "default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
            response.headers[.referrerPolicy] = "no-referrer"
            response.headers[.xContentTypeOptions] = "nosniff"
        }
        return response
    }
}

extension HTTPField.Name {
    static let referrerPolicy = Self("Referrer-Policy")!
}
