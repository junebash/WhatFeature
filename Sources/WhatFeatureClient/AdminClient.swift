public import AsyncHTTPClient
public import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
public import WhatFeatureAPI
public import WhatFeatureCore
public import WhatFeatureStorage

/// A typed client for `/admin/v1`. One method per endpoint; projects and environments are passed by key.
public struct AdminClient: Sendable {
    /// e.g. `http://localhost:8080`. Paths are added to it.
    public var baseURL: URL
    /// An admin token's secret.
    public var token: String
    private let http: HTTPClient

    public init(baseURL: URL, token: String, httpClient: HTTPClient = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.http = httpClient
    }

    // MARK: - Me

    /// The token this client uses. Fails with `401`/`403` if it isn't a working admin token.
    public func me() async throws -> Token {
        try await send(.GET, "me")
    }

    // MARK: - Projects

    public func projects() async throws -> [Project] {
        try await send(.GET, "projects")
    }

    public func project(_ key: String) async throws -> Project {
        try await send(.GET, "projects/\(key)")
    }

    public func createProject(key: String, name: String? = nil) async throws -> Project {
        try await send(.POST, "projects", body: CreateProjectRequest(key: key, name: name))
    }

    // MARK: - Environments

    public func environments(project: String) async throws -> [WhatFeatureStorage.Environment] {
        try await send(.GET, "projects/\(project)/environments")
    }

    public func createEnvironment(project: String, key: String, name: String? = nil) async throws -> WhatFeatureStorage.Environment {
        try await send(.POST, "projects/\(project)/environments", body: CreateEnvironmentRequest(key: key, name: name))
    }

    // MARK: - Flags

    public enum FlagSort: String, Sendable, CaseIterable {
        case key, createdAt
    }

    public func flags(
        project: String,
        includeArchived: Bool = false,
        createdBy: String? = nil,
        sort: FlagSort = .key,
        descending: Bool = false
    ) async throws -> [Flag] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "order", value: descending ? "desc" : "asc"),
        ]
        if includeArchived { query.append(URLQueryItem(name: "includeArchived", value: "true")) }
        if let createdBy { query.append(URLQueryItem(name: "createdBy", value: createdBy)) }
        return try await send(.GET, "projects/\(project)/flags", query: query)
    }

    public func flag(project: String, key: String) async throws -> FlagDetail {
        try await send(.GET, "projects/\(project)/flags/\(key)")
    }

    public func createFlag(project: String, _ request: CreateFlagRequest) async throws -> FlagDetail {
        try await send(.POST, "projects/\(project)/flags", body: request)
    }

    public func updateFlag(project: String, key: String, changes: SQLiteStore.FlagChanges) async throws -> FlagDetail {
        try await send(.PATCH, "projects/\(project)/flags/\(key)", body: changes)
    }

    public func deleteFlag(project: String, key: String) async throws {
        let _: Empty = try await send(.DELETE, "projects/\(project)/flags/\(key)")
    }

    public func setArchived(_ archived: Bool, project: String, key: String) async throws -> FlagDetail {
        try await send(.POST, "projects/\(project)/flags/\(key)/\(archived ? "archive" : "unarchive")")
    }

    // MARK: - Configs

    public func config(project: String, environment: String, flag: String) async throws -> FlagConfig {
        try await send(.GET, "projects/\(project)/environments/\(environment)/flags/\(flag)")
    }

    /// Returns the saved config, with its new version.
    public func setConfig(_ config: FlagConfig, project: String, environment: String, flag: String) async throws -> FlagConfig {
        try await send(.PUT, "projects/\(project)/environments/\(environment)/flags/\(flag)", body: config)
    }

    /// What `context` would get, and why. Stores nothing.
    public func evaluate(project: String, environment: String, flag: String, context: EvaluationContext) async throws -> DryRunResult {
        try await send(.POST, "projects/\(project)/environments/\(environment)/flags/\(flag)/evaluate", body: DryRunRequest(context: context))
    }

    // MARK: - Tokens

    public func tokens() async throws -> [Token] {
        try await send(.GET, "tokens")
    }

    public func createToken(_ request: CreateTokenRequest) async throws -> CreatedTokenResponse {
        try await send(.POST, "tokens", body: request)
    }

    public func revokeToken(_ id: TokenID) async throws -> Token {
        try await send(.POST, "tokens/\(id)/revoke")
    }

    // MARK: - Audit

    public func audit(
        project: String? = nil,
        flag: String? = nil,
        actor: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int? = nil
    ) async throws -> [AuditEntryResponse] {
        var query: [URLQueryItem] = []
        if let project { query.append(URLQueryItem(name: "project", value: project)) }
        if let flag { query.append(URLQueryItem(name: "flag", value: flag)) }
        if let actor { query.append(URLQueryItem(name: "actor", value: actor)) }
        if let since { query.append(URLQueryItem(name: "since", value: since.formatted(.iso8601))) }
        if let until { query.append(URLQueryItem(name: "until", value: until.formatted(.iso8601))) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await send(.GET, "audit", query: query)
    }

    // MARK: - Transport

    private struct Empty: Codable {}

    private static let maxResponseSize = 16 * 1_024 * 1_024

    private func send<Response: Decodable>(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await send(method, path, query: query, bodyData: nil)
    }

    private func send<Response: Decodable>(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        body: some Encodable
    ) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try await send(method, path, query: query, bodyData: try encoder.encode(body))
    }

    private func send<Response: Decodable>(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem],
        bodyData: Data?
    ) async throws -> Response {
        let url = try url(path, query: query)
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "Accept", value: "application/json")
        if let bodyData {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(data: bodyData))
        }

        let response = try await http.execute(request, timeout: .seconds(30))
        let body = try await response.body.collect(upTo: Self.maxResponseSize)
        let data = Data(buffer: body)

        guard (200..<300).contains(response.status.code) else {
            if let error = try? JSONDecoder().decode(AdminErrorBody.self, from: data) {
                throw AdminClientError.server(status: Int(response.status.code), body: error)
            }
            throw AdminClientError.unexpected(status: Int(response.status.code), body: String(decoding: data, as: UTF8.self))
        }
        if Response.self == Empty.self, data.isEmpty {
            return Empty() as! Response
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private func url(_ path: String, query: [URLQueryItem]) throws -> URL {
        let url = baseURL.appending(path: "admin/v1/\(path)")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AdminClientError.invalidURL(url.absoluteString)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let result = components.url else { throw AdminClientError.invalidURL(url.absoluteString) }
        return result
    }
}

public enum AdminClientError: Error, CustomStringConvertible {
    /// The server answered with an admin API error body.
    case server(status: Int, body: AdminErrorBody)
    /// The server answered with something else, e.g. a `502` from a proxy.
    case unexpected(status: Int, body: String)
    case invalidURL(String)

    public var status: Int? {
        switch self {
        case .server(let status, _), .unexpected(let status, _): status
        case .invalidURL: nil
        }
    }

    public var description: String {
        switch self {
        case .server(let status, let body):
            let issues = (body.issues ?? []).map { "\n  - \($0)" }.joined()
            return "\(body.error) (HTTP \(status))\(issues)"
        case .unexpected(let status, let body):
            return "Unexpected response (HTTP \(status))" + (body.isEmpty ? "" : ": \(body.prefix(200))")
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        }
    }
}
