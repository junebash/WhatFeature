import Foundation
import Hummingbird
import HummingbirdCore
import NIOCore
import NIOFoundationCompat
import WhatFeatureAPI
import WhatFeatureCore
import WhatFeatureStorage

/// `/admin/v1`. Projects and environments are addressed by key in paths; tokens by ID.
struct AdminRoutes {
    typealias Context = WhatFeatureRequestContext

    let store: SQLiteStore
    /// `nil` on a server without a tracking database: settings still work, reading tracking data doesn't.
    let tracking: TrackingRecorder?

    func register(on group: RouterGroup<Context>) {
        typealias Paths = AdminPaths
        func path(_ string: String) -> RouterPath { RouterPath(string) }

        group.get(path(Paths.me), use: me)

        group.get(path(Paths.projects), use: listProjects)
        group.post(path(Paths.projects), use: createProject)
        group.get(path(Paths.project(.project)), use: getProject)
        group.patch(path(Paths.project(.project)), use: updateProject)
        group.post(path(Paths.archive(Paths.project(.project))), use: archiveProject)
        group.post(path(Paths.unarchive(Paths.project(.project))), use: unarchiveProject)

        group.get(path(Paths.environments(.project)), use: listEnvironments)
        group.post(path(Paths.environments(.project)), use: createEnvironment)
        group.patch(path(Paths.environment(.project, .environment)), use: updateEnvironment)
        group.post(path(Paths.archive(Paths.environment(.project, .environment))), use: archiveEnvironment)
        group.post(path(Paths.unarchive(Paths.environment(.project, .environment))), use: unarchiveEnvironment)

        group.get(path(Paths.flags(.project)), use: listFlags)
        group.post(path(Paths.flags(.project)), use: createFlag)
        group.get(path(Paths.flag(.project, .flag)), use: getFlag)
        group.patch(path(Paths.flag(.project, .flag)), use: updateFlag)
        group.delete(path(Paths.flag(.project, .flag)), use: deleteFlag)
        group.post(path(Paths.archive(Paths.flag(.project, .flag))), use: archiveFlag)
        group.post(path(Paths.unarchive(Paths.flag(.project, .flag))), use: unarchiveFlag)

        group.get(path(Paths.config(.project, .environment, .flag)), use: getConfig)
        group.put(path(Paths.config(.project, .environment, .flag)), use: setConfig)
        group.post(path(Paths.evaluate(.project, .environment, .flag)), use: dryRun)
        group.post(path(Paths.evaluateAll(.project, .environment)), use: dryRunAll)

        group.get(path(Paths.tracking(.project, .environment)), use: getTracking)
        group.put(path(Paths.tracking(.project, .environment)), use: setTracking)
        group.get(path(Paths.trackedContexts(.project, .environment)), use: listTrackedContexts)
        group.get(path(Paths.trackedContext(.project, .environment)), use: getTrackedContext)
        group.delete(path(Paths.trackedContext(.project, .environment)), use: deleteTrackedContext)
        group.get(path(Paths.exposures(.project, .environment)), use: listExposures)

        group.get(path(Paths.tokens), use: listTokens)
        group.post(path(Paths.tokens), use: createToken)
        group.post(path(Paths.revokeToken(.token)), use: revokeToken)

        group.get(path(Paths.audit), use: listAudit)
    }

    /// The admin token making the request. Handy for checking that a token works.
    @Sendable func me(_ request: Request, context: Context) async throws -> Response {
        guard let token = context.adminToken else { throw HTTPError(.internalServerError) }
        return try .json(token, status: .ok)
    }

    // MARK: - Projects

    /// Query: `includeArchived=true`.
    @Sendable func listProjects(_ request: Request, context: Context) async throws -> Response {
        try .json(try await store.projects(includeArchived: request.includeArchived), status: .ok)
    }

    @Sendable func createProject(_ request: Request, context: Context) async throws -> Response {
        let body = try await request.decodeJSON(CreateProjectRequest.self)
        let project = try await store.createProject(key: body.key, name: body.name ?? body.key, by: context.actor)
        return try .json(project, status: .created)
    }

    @Sendable func getProject(_ request: Request, context: Context) async throws -> Response {
        try .json(try await project(context), status: .ok)
    }

    /// Body: either or both of `key` and `name`.
    @Sendable func updateProject(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        let changes = try await request.decodeJSON(SQLiteStore.NameChanges.self)
        return try .json(try await store.updateProject(project.id, changes: changes, by: context.actor), status: .ok)
    }

    @Sendable func archiveProject(_ request: Request, context: Context) async throws -> Response {
        try .json(try await store.setArchived(true, project: try await project(context).id, by: context.actor), status: .ok)
    }

    @Sendable func unarchiveProject(_ request: Request, context: Context) async throws -> Response {
        try .json(try await store.setArchived(false, project: try await project(context).id, by: context.actor), status: .ok)
    }

    // MARK: - Environments

    /// Query: `includeArchived=true`.
    @Sendable func listEnvironments(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        return try .json(try await store.environments(in: project.id, includeArchived: request.includeArchived), status: .ok)
    }

    @Sendable func createEnvironment(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        let body = try await request.decodeJSON(CreateEnvironmentRequest.self)
        let environment = try await store.createEnvironment(key: body.key, name: body.name ?? body.key, in: project.id, by: context.actor)
        return try .json(environment, status: .created)
    }

    /// Body: either or both of `key` and `name`.
    @Sendable func updateEnvironment(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        let changes = try await request.decodeJSON(SQLiteStore.NameChanges.self)
        return try .json(try await store.updateEnvironment(environment.id, changes: changes, by: context.actor), status: .ok)
    }

    @Sendable func archiveEnvironment(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        return try .json(try await store.setArchived(true, environment: environment.id, by: context.actor), status: .ok)
    }

    @Sendable func unarchiveEnvironment(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        return try .json(try await store.setArchived(false, environment: environment.id, by: context.actor), status: .ok)
    }

    // MARK: - Flags

    /// Query: `includeArchived=true`, `createdBy=token:<id>`, `sort=key|createdAt`, `order=asc|desc`.
    @Sendable func listFlags(_ request: Request, context: Context) async throws -> Response {
        let project = try await project(context)
        let query = request.uri.queryParameters
        var flags = try await store.flags(in: project.id, includeArchived: request.includeArchived)
        if let createdBy = query[Substring(AdminPaths.Query.Flags.createdBy)] {
            flags = flags.filter { $0.createdBy == createdBy }
        }
        switch query[Substring(AdminPaths.Query.Flags.sort)].map(String.init) ?? "key" {
        case "key": break  // already sorted by key
        case "createdAt": flags.sort { ($0.createdAt, $0.key) < ($1.createdAt, $1.key) }
        case let other: throw AdminRequestError(message: "Unknown sort '\(other)'. Use 'key' or 'createdAt'.")
        }
        switch query[Substring(AdminPaths.Query.Flags.order)].map(String.init) ?? "asc" {
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

    /// "What would this context get, and why?" Uses the live config and stores nothing. Evaluates through
    /// the same code as the OFREP endpoint, and includes exactly what an app would get from it.
    @Sendable func dryRun(_ request: Request, context: Context) async throws -> Response {
        let (_, environment, flag) = try await projectEnvironmentAndFlag(context)
        let body = try await request.decodeJSON(DryRunRequest.self)
        let snapshot = try await store.snapshot(for: environment.id)
        guard snapshot.entries[flag.key] != nil else {
            throw StoreError.notFound("No config for '\(flag.key)' in '\(environment.key)'")
        }
        let result = snapshot.evaluate(flagKey: flag.key, context: body.context)
        return try .json(try Self.dryRunResult(result, in: snapshot), status: .ok)
    }

    /// The dry run for every flag at once: what OFREP's bulk endpoint would send.
    @Sendable func dryRunAll(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        let body = try await request.decodeJSON(DryRunRequest.self)
        let snapshot = try await store.snapshot(for: environment.id)
        let results = snapshot.evaluateAll(context: body.context)
        let bulk = OFREPReply(status: 200, body: try JSONValue(encoding: OFREPBulkResponse(results, in: snapshot)))
        return try .json(BulkDryRunResult(flags: try results.map { try Self.dryRunResult($0, in: snapshot) }, ofrep: bulk), status: .ok)
    }

    private static func dryRunResult(_ result: EvaluationResult, in snapshot: EnvironmentSnapshot) throws -> DryRunResult {
        let evaluation = OFREPEvaluation(result: result, in: snapshot)
        return DryRunResult(
            result,
            configVersion: snapshot.entries[result.flagKey]?.config.version ?? 0,
            ofrep: OFREPReply(status: Int(evaluation.status.code), body: try JSONValue(encoding: evaluation))
        )
    }

    // MARK: - Tracking

    @Sendable func getTracking(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        return try .json(environment.tracking, status: .ok)
    }

    /// Body: a whole `TrackingSettings`. What the new settings no longer allow (attributes taken off the list, contexts
    /// past a shorter retention) is deleted before this answers.
    @Sendable func setTracking(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        let settings = try await request.decodeJSON(TrackingSettings.self)
        let saved = try await store.setTracking(settings, environment: environment.id, by: context.actor).tracking
        try await tracking?.apply(saved, to: environment.id)
        return try .json(saved, status: .ok)
    }

    /// Query: `since` (ISO 8601, compared with `lastSeen`), `limit` (1–1000, default 100). Most recently seen first.
    @Sendable func listTrackedContexts(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        let query = request.uri.queryParameters
        let contexts = try await requireTracking().trackingStore.seenContexts(
            in: environment.id,
            since: try query.date(AdminPaths.Query.Tracking.since),
            limit: try query.limit(AdminPaths.Query.Tracking.limit, default: 100, max: 1_000)
        )
        return try .json(contexts, status: .ok)
    }

    /// Query: `targetingKey`. The key's latest attributes and every exposure.
    @Sendable func getTrackedContext(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        let targetingKey = try request.uri.queryParameters.targetingKey
        let trackingStore = try requireTracking().trackingStore
        guard let seen = try await trackingStore.seenContext(targetingKey, in: environment.id) else {
            throw StoreError.notFound("Nothing is stored for that targeting key in '\(environment.key)'")
        }
        let exposures = try await trackingStore.exposures(in: environment.id, targetingKey: targetingKey)
        return try .json(TrackedContextDetail(context: seen, exposures: exposures), status: .ok)
    }

    /// Query: `targetingKey`. Deletes everything stored for it, and audits the deletion without the key.
    @Sendable func deleteTrackedContext(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        let targetingKey = try request.uri.queryParameters.targetingKey
        guard try await requireTracking().deleteContext(targetingKey, in: environment.id) else {
            throw StoreError.notFound("Nothing is stored for that targeting key in '\(environment.key)'")
        }
        try await store.auditTrackingDeletion(in: environment.id, by: context.actor)
        return Response(status: .noContent)
    }

    /// Query: `targetingKey`, `flag`, `variant`, `since` (ISO 8601, compared with `lastServed`), `limit` (1–100000,
    /// default 10000). Sorted by targeting key, flag, then first served.
    @Sendable func listExposures(_ request: Request, context: Context) async throws -> Response {
        let (_, environment) = try await projectAndEnvironment(context)
        let query = request.uri.queryParameters
        let exposures = try await requireTracking().trackingStore.exposures(
            in: environment.id,
            targetingKey: query[Substring(AdminPaths.Query.Tracking.targetingKey)].map(String.init),
            flagKey: query[Substring(AdminPaths.Query.Tracking.flag)].map(String.init),
            variant: query[Substring(AdminPaths.Query.Tracking.variant)].map(String.init),
            since: try query.date(AdminPaths.Query.Tracking.since),
            limit: try query.limit(AdminPaths.Query.Tracking.limit, default: 10_000, max: 100_000)
        )
        return try .json(exposures, status: .ok)
    }

    private func requireTracking() throws -> TrackingRecorder {
        guard let tracking else { throw StoreError.notFound("This server has no tracking database") }
        return tracking
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
        let id = try context.parameters.require(AdminPaths.Parameter.token.rawValue)
        return try .json(try await store.revokeToken(TokenID(id), by: context.actor), status: .ok)
    }

    // MARK: - Audit

    /// Query: `project=<key>`, `flag=<key>`, `actor=token:<id>`, `since`/`until` (ISO 8601), `limit` (1–1000, default 100).
    @Sendable func listAudit(_ request: Request, context: Context) async throws -> Response {
        let query = request.uri.queryParameters
        var projectID: ProjectID?
        if let key = query[Substring(AdminPaths.Query.Audit.project)].map(String.init) {
            guard let project = try await store.project(key: key) else {
                throw StoreError.notFound("No project with key '\(key)'")
            }
            projectID = project.id
        }
        let entries = try await store.auditEntries(
            projectID: projectID,
            flagKey: query[Substring(AdminPaths.Query.Audit.flag)].map(String.init),
            actor: query[Substring(AdminPaths.Query.Audit.actor)].map(String.init),
            since: try query.date(AdminPaths.Query.Audit.since),
            until: try query.date(AdminPaths.Query.Audit.until),
            limit: try query.limit(AdminPaths.Query.Audit.limit, default: 100, max: 1_000)
        )
        return try .json(entries.map(AuditEntryResponse.init), status: .ok)
    }

    // MARK: - Lookups

    private func project(_ context: Context) async throws -> Project {
        let key = try context.parameters.require(AdminPaths.Parameter.project.rawValue)
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

    private func projectAndEnvironment(_ context: Context) async throws -> (Project, WhatFeatureStorage.Environment) {
        let project = try await project(context)
        let key = try context.parameters.require(AdminPaths.Parameter.environment.rawValue)
        guard let environment = try await store.environment(key: key, in: project.id) else {
            throw StoreError.notFound("No environment '\(key)' in '\(project.key)'")
        }
        return (project, environment)
    }

    private func projectEnvironmentAndFlag(_ context: Context) async throws -> (Project, WhatFeatureStorage.Environment, Flag) {
        let (project, environment) = try await projectAndEnvironment(context)
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
        get throws { try parameters.require(AdminPaths.Parameter.flag.rawValue) }
    }
}

extension FlatDictionary<Substring, Substring> {
    func date(_ name: String) throws -> Date? {
        guard let value = self[Substring(name)] else { return nil }
        guard let date = try? Date(String(value), strategy: .iso8601) else {
            throw AdminRequestError(message: "'\(name)' must be an ISO 8601 date, like 2026-10-31T12:00:00Z")
        }
        return date
    }

    func limit(_ name: String, default defaultValue: Int, max: Int) throws -> Int {
        let limit = self[Substring(name)].map { Int($0) ?? -1 } ?? defaultValue
        guard (1...max).contains(limit) else {
            throw AdminRequestError(message: "'\(name)' must be a number from 1 to \(max)")
        }
        return limit
    }

    var targetingKey: String {
        get throws {
            guard let key = self[Substring(AdminPaths.Query.Tracking.targetingKey)], !key.isEmpty else {
                throw AdminRequestError(message: "'\(AdminPaths.Query.Tracking.targetingKey)' is required")
            }
            return String(key)
        }
    }
}

extension Request {
    var includeArchived: Bool {
        uri.queryParameters[Substring(AdminPaths.Query.includeArchived)] == "true"
    }

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
