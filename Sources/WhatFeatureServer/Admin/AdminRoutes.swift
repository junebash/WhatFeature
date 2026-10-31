import Foundation
import Hummingbird
import NIOCore
import NIOFoundationCompat
import WhatFeatureAPI
import WhatFeatureCore
import WhatFeatureStorage

/// `/admin/v1`. Projects and environments are addressed by key in paths; tokens by ID.
struct AdminRoutes {
    typealias Context = WhatFeatureRequestContext

    let store: SQLiteStore

    func register(on group: RouterGroup<Context>) {
        group.get("projects", use: listProjects)
        group.post("projects", use: createProject)
        group.get("projects/{project}", use: getProject)

        group.get("projects/{project}/environments", use: listEnvironments)
        group.post("projects/{project}/environments", use: createEnvironment)

        group.get("projects/{project}/flags", use: listFlags)
        group.post("projects/{project}/flags", use: createFlag)
        group.get("projects/{project}/flags/{flag}", use: getFlag)
        group.patch("projects/{project}/flags/{flag}", use: updateFlag)
        group.delete("projects/{project}/flags/{flag}", use: deleteFlag)
        group.post("projects/{project}/flags/{flag}/archive", use: archiveFlag)
        group.post("projects/{project}/flags/{flag}/unarchive", use: unarchiveFlag)

        group.get("projects/{project}/environments/{environment}/flags/{flag}", use: getConfig)
        group.put("projects/{project}/environments/{environment}/flags/{flag}", use: setConfig)
        group.post("projects/{project}/environments/{environment}/flags/{flag}/evaluate", use: dryRun)

        group.get("tokens", use: listTokens)
        group.post("tokens", use: createToken)
        group.post("tokens/{token}/revoke", use: revokeToken)

        group.get("audit", use: listAudit)

        group.get("me", use: me)
    }

    /// The admin token making the request. Handy for checking that a token works.
    @Sendable func me(_ request: Request, context: Context) async throws -> Response {
        guard let token = context.adminToken else { throw HTTPError(.internalServerError) }
        return try .json(token, status: .ok)
    }

    // MARK: - Projects

    @Sendable func listProjects(_ request: Request, context: Context) async throws -> Response {
        try .json(try await store.projects(), status: .ok)
    }

    @Sendable func createProject(_ request: Request, context: Context) async throws -> Response {
        let body = try await request.decodeJSON(CreateProjectRequest.self)
        let project = try await store.createProject(key: body.key, name: body.name ?? body.key, by: context.actor)
        return try .json(project, status: .created)
    }

    @Sendable func getProject(_ request: Request, context: Context) async throws -> Response {
        try .json(try await project(context), status: .ok)
    }

    // MARK: - Environments

    @Sendable func listEnvironments(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        return try .json(try await store.environments(in: project.id), status: .ok)
    }

    @Sendable func createEnvironment(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        let body = try await request.decodeJSON(CreateEnvironmentRequest.self)
        let environment = try await store.createEnvironment(key: body.key, name: body.name ?? body.key, in: project.id, by: context.actor)
        return try .json(environment, status: .created)
    }

    // MARK: - Flags

    /// Query: `includeArchived=true`, `createdBy=token:<id>`, `sort=key|createdAt`, `order=asc|desc`.
    @Sendable func listFlags(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        let query = request.uri.queryParameters
        var flags = try await store.flags(in: project.id, includeArchived: query["includeArchived"] == "true")
        if let createdBy = query["createdBy"] {
            flags = flags.filter { $0.createdBy == createdBy }
        }
        switch query["sort"].map(String.init) ?? "key" {
        case "key": break  // already sorted by key
        case "createdAt": flags.sort { ($0.createdAt, $0.key) < ($1.createdAt, $1.key) }
        case let other: throw AdminRequestError(message: "Unknown sort '\(other)'. Use 'key' or 'createdAt'.")
        }
        switch query["order"].map(String.init) ?? "asc" {
        case "asc": break
        case "desc": flags.reverse()
        case let other: throw AdminRequestError(message: "Unknown order '\(other)'. Use 'asc' or 'desc'.")
        }
        return try .json(flags, status: .ok)
    }

    @Sendable func createFlag(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        let body = try await request.decodeJSON(CreateFlagRequest.self)
        let flag = try await store.createFlag(
            key: body.key, type: body.type, variants: body.variants,
            description: body.description ?? "", isExperiment: body.isExperiment ?? false,
            defaultVariant: body.defaultVariant, in: project.id, by: context.actor
        )
        return try .json(try await detail(of: flag, in: project), status: .created)
    }

    @Sendable func getFlag(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        return try .json(try await detail(of: try await flag(context, in: project), in: project), status: .ok)
    }

    /// Body: any of `description`, `variants`, `isExperiment`.
    @Sendable func updateFlag(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        let changes = try await request.decodeJSON(SQLiteStore.FlagChanges.self)
        let flag = try await store.updateFlag(key: try context.flagKey, in: project.id, changes: changes, by: context.actor)
        return try .json(try await detail(of: flag, in: project), status: .ok)
    }

    @Sendable func deleteFlag(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        try await store.deleteFlag(key: try context.flagKey, in: project.id, by: context.actor)
        return Response(status: .noContent)
    }

    @Sendable func archiveFlag(_ request: Request, context: Context) async throws -> Response {
        try await setArchived(true, context)
    }

    @Sendable func unarchiveFlag(_ request: Request, context: Context) async throws -> Response {
        try await setArchived(false, context)
    }

    private func setArchived(_ archived: Bool, _ context: Context) async throws -> Response {
        let project = try await project(context)
        let flag = try await store.setArchived(archived, flagKey: try context.flagKey, in: project.id, by: context.actor)
        return try .json(try await detail(of: flag, in: project), status: .ok)
    }

    // MARK: - Configs

    @Sendable func getConfig(_ request: Request, context: Context) async throws -> Response {
        let (_, environment, flag) = try await projectEnvironmentAndFlag(context)
        guard let config = try await store.config(flagKey: flag.key, in: environment.id) else {
            throw StoreError.notFound("No config for '\(flag.key)' in '\(environment.key)'")
        }
        return try .json(config, status: .ok)
    }

    /// Body: a whole `FlagConfig`. Any `version` in it is ignored; the response has the new one.
    @Sendable func setConfig(_ request: Request, context: Context) async throws -> Response {
        let (_, environment, flag) = try await projectEnvironmentAndFlag(context)
        let config = try await request.decodeJSON(FlagConfig.self)
        let saved = try await store.setConfig(config, flagKey: flag.key, in: environment.id, by: context.actor)
        return try .json(saved, status: .ok)
    }

    /// "What would this context get, and why?" Uses the live config and stores nothing.
    @Sendable func dryRun(_ request: Request, context: Context) async throws -> Response {
        let (_, environment, flag) = try await projectEnvironmentAndFlag(context)
        let body = try await request.decodeJSON(DryRunRequest.self)
        let snapshot = try await store.snapshot(for: environment.id)
        guard let entry = snapshot.entries[flag.key] else {
            throw StoreError.notFound("No config for '\(flag.key)' in '\(environment.key)'")
        }
        let result = entry.evaluate(context: body.context)
        return try .json(DryRunResult(result, configVersion: entry.config.version), status: .ok)
    }

    // MARK: - Tokens

    @Sendable func listTokens(_ request: Request, context: Context) async throws -> Response {
        try .json(try await store.tokens(), status: .ok)
    }

    @Sendable func createToken(_ request: Request, context: Context) async throws -> Response {
        let body = try await request.decodeJSON(CreateTokenRequest.self)
        let created: SQLiteStore.CreatedToken
        switch (body.kind, body.project, body.environment) {
        case (.admin, nil, nil):
            created = try await store.createAdminToken(name: body.name, by: context.actor)
        case (.evaluation, let projectKey?, let environmentKey?):
            guard let project = try await store.project(key: projectKey) else {
                throw StoreError.notFound("No project with key '\(projectKey)'")
            }
            guard let environment = try await store.environment(key: environmentKey, in: project.id) else {
                throw StoreError.notFound("No environment '\(environmentKey)' in '\(projectKey)'")
            }
            created = try await store.createEvaluationToken(name: body.name, for: environment.id, by: context.actor)
        case (.admin, _, _):
            throw AdminRequestError(message: "Admin tokens don't take a project or environment")
        case (.evaluation, _, _):
            throw AdminRequestError(message: "Evaluation tokens need both 'project' and 'environment'")
        }
        return try .json(CreatedTokenResponse(token: created.token, secret: created.secret), status: .created)
    }

    @Sendable func revokeToken(_ request: Request, context: Context) async throws -> Response {
        let id = try context.parameters.require("token")
        return try .json(try await store.revokeToken(TokenID(id), by: context.actor), status: .ok)
    }

    // MARK: - Audit

    /// Query: `project=<key>`, `flag=<key>`, `actor=token:<id>`, `since`/`until` (ISO 8601), `limit` (1–1000, default 100).
    @Sendable func listAudit(_ request: Request, context: Context) async throws -> Response {
        let query = request.uri.queryParameters
        var projectID: ProjectID?
        if let key = query["project"].map(String.init) {
            guard let project = try await store.project(key: key) else {
                throw StoreError.notFound("No project with key '\(key)'")
            }
            projectID = project.id
        }
        func date(_ name: Substring) throws -> Date? {
            guard let value = query[name] else { return nil }
            guard let date = try? Date(String(value), strategy: .iso8601) else {
                throw AdminRequestError(message: "'\(name)' must be an ISO 8601 date, like 2026-10-31T12:00:00Z")
            }
            return date
        }
        let limit = query["limit"].map { Int($0) ?? -1 } ?? 100
        guard (1...1_000).contains(limit) else {
            throw AdminRequestError(message: "'limit' must be a number from 1 to 1000")
        }

        let entries = try await store.auditEntries(
            projectID: projectID,
            flagKey: query["flag"].map(String.init),
            actor: query["actor"].map(String.init),
            since: try date("since"),
            until: try date("until"),
            limit: limit
        )
        return try .json(entries.map(AuditEntryResponse.init), status: .ok)
    }

    // MARK: - Lookups

    private func project(_ context: Context) async throws -> Project {
        let key = try context.parameters.require("project")
        guard let project = try await store.project(key: key) else {
            throw StoreError.notFound("No project with key '\(key)'")
        }
        return project
    }

    private func flag(_ context: Context, in project: Project) async throws -> Flag {
        let key = try context.flagKey
        guard let flag = try await store.flag(key: key, in: project.id) else {
            throw StoreError.notFound("No flag with key '\(key)'")
        }
        return flag
    }

    private func projectEnvironmentAndFlag(_ context: Context) async throws -> (Project, WhatFeatureStorage.Environment, Flag) {
        let project = try await project(context)
        let key = try context.parameters.require("environment")
        guard let environment = try await store.environment(key: key, in: project.id) else {
            throw StoreError.notFound("No environment '\(key)' in '\(project.key)'")
        }
        return (project, environment, try await flag(context, in: project))
    }

    private func detail(of flag: Flag, in project: Project) async throws -> FlagDetail {
        var configs: [String: FlagConfig] = [:]
        for environment in try await store.environments(in: project.id) {
            configs[environment.key] = try await store.config(flagKey: flag.key, in: environment.id)
        }
        return FlagDetail(flag: flag, configs: configs)
    }
}

extension WhatFeatureRequestContext {
    /// Who to record in the audit log. The middleware guarantees an admin token.
    var actor: AuditActor {
        adminToken.map { .token($0.id) } ?? .system("unknown")
    }

    var flagKey: String {
        get throws { try parameters.require("flag") }
    }
}

extension Request {
    /// Admin request bodies are small; anything bigger is a mistake.
    static let maxAdminBodySize = 1_024 * 1_024

    func decodeJSON<T: Decodable>(_: T.Type) async throws -> T {
        let body = try await self.body.collect(upTo: Self.maxAdminBodySize)
        do {
            return try JSONDecoder.whatFeature.decode(T.self, from: body)
        } catch let error as DecodingError {
            throw AdminRequestError(message: "Invalid request body: \(error.summary)")
        }
    }
}
