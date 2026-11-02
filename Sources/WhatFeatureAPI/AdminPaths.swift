/// Every admin API path, relative to `/admin/v1`, defined once.
///
/// The server registers its routes by calling these with placeholders (`AdminPaths.flag(.project, .flag)`
/// gives `projects/{project}/flags/{flag}`); the client calls them with real keys. So the two can't disagree
/// about a path.
public enum AdminPaths {
    public static let prefix = "admin/v1"

    public static let me = "me"
    public static let projects = "projects"
    public static func project(_ project: String) -> String { "projects/\(project)" }

    public static func environments(_ project: String) -> String { self.project(project) + "/environments" }
    public static func environment(_ project: String, _ environment: String) -> String { environments(project) + "/\(environment)" }

    public static func flags(_ project: String) -> String { self.project(project) + "/flags" }
    public static func flag(_ project: String, _ flag: String) -> String { flags(project) + "/\(flag)" }
    /// For a project, an environment or a flag: `archive(flag("demo", "beta"))`.
    public static func archive(_ path: String) -> String { path + "/archive" }
    public static func unarchive(_ path: String) -> String { path + "/unarchive" }

    public static func config(_ project: String, _ environment: String, _ flag: String) -> String {
        self.environment(project, environment) + "/flags/\(flag)"
    }
    public static func evaluate(_ project: String, _ environment: String, _ flag: String) -> String {
        config(project, environment, flag) + "/evaluate"
    }
    /// Every flag at once, like OFREP's bulk endpoint.
    public static func evaluateAll(_ project: String, _ environment: String) -> String {
        self.environment(project, environment) + "/evaluate"
    }

    public static let tokens = "tokens"
    public static func revokeToken(_ id: String) -> String { "tokens/\(id)/revoke" }

    public static let audit = "audit"

    /// Path parameters, as the server names them.
    public enum Parameter: String, Sendable, CaseIterable {
        case project, environment, flag, token

        /// `{project}`, the form the server's router expects.
        public var placeholder: String { "{\(rawValue)}" }
    }

    /// Query parameter names.
    public enum Query {
        /// For projects, environments and flags.
        public static let includeArchived = "includeArchived"

        public enum Flags {
            public static let createdBy = "createdBy"
            public static let sort = "sort"
            public static let order = "order"
        }

        public enum Audit {
            public static let project = "project"
            public static let flag = "flag"
            public static let actor = "actor"
            public static let since = "since"
            public static let until = "until"
            public static let limit = "limit"
        }
    }
}

extension AdminPaths {
    // Placeholder overloads, so the server can write `AdminPaths.flag(.project, .flag)`.
    public static func project(_ project: Parameter) -> String { self.project(project.placeholder) }
    public static func environments(_ project: Parameter) -> String { environments(project.placeholder) }
    public static func flags(_ project: Parameter) -> String { flags(project.placeholder) }
    public static func flag(_ project: Parameter, _ flag: Parameter) -> String { self.flag(project.placeholder, flag.placeholder) }
    public static func environment(_ project: Parameter, _ environment: Parameter) -> String {
        self.environment(project.placeholder, environment.placeholder)
    }
    public static func config(_ project: Parameter, _ environment: Parameter, _ flag: Parameter) -> String {
        config(project.placeholder, environment.placeholder, flag.placeholder)
    }
    public static func evaluate(_ project: Parameter, _ environment: Parameter, _ flag: Parameter) -> String {
        evaluate(project.placeholder, environment.placeholder, flag.placeholder)
    }
    public static func evaluateAll(_ project: Parameter, _ environment: Parameter) -> String {
        evaluateAll(project.placeholder, environment.placeholder)
    }
    public static func revokeToken(_ id: Parameter) -> String { revokeToken(id.placeholder) }
}
