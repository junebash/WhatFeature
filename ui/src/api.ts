// The admin API (/admin/v1), typed. Mirrors WhatFeatureAPI's AdminPaths and AdminMessages and the models they use;
// docs/DESIGN.md ("Admin") describes every endpoint.

export type JSONValue = null | boolean | number | string | JSONArray | JSONObject
// Interfaces rather than inline types, so TypeScript (and Vue's ref unwrapping) expand them lazily.
export interface JSONArray extends Array<JSONValue> {}
export interface JSONObject {
  [key: string]: JSONValue
}

export interface Project {
  id: string
  key: string
  name: string
  createdAt: string
  archivedAt?: string
}

export interface TrackingSettings {
  enabled: boolean
  attributes: string[]
  retentionDays: number
}

export interface Environment {
  id: string
  projectID: string
  key: string
  name: string
  version: number
  createdAt: string
  archivedAt?: string
  tracking: TrackingSettings
}

export type FlagType = 'boolean' | 'string' | 'number' | 'object'
export const flagTypes: FlagType[] = ['boolean', 'string', 'number', 'object']

export interface Flag {
  key: string
  type: FlagType
  variants: Record<string, JSONValue>
  description: string
  isExperiment: boolean
  createdBy: string
  createdAt: string
  archivedAt?: string
}

export type Operator =
  | 'equals' | 'notEquals' | 'in' | 'notIn'
  | 'startsWith' | 'endsWith' | 'contains'
  | 'eq' | 'lt' | 'lte' | 'gt' | 'gte'
  | 'semverEq' | 'semverLt' | 'semverLte' | 'semverGt' | 'semverGte'
  | 'exists' | 'notExists'

export interface Condition {
  attribute: string
  operator: Operator
  value?: JSONValue
}

export interface WeightedVariant {
  variant: string
  /** Out of 10,000: 1,000 is 10%. */
  weight: number
}

export type RuleResult = { variant: string } | { rollout: WeightedVariant[] }

export interface Rule {
  conditions: Condition[]
  result: RuleResult
}

export interface FlagConfig {
  enabled: boolean
  rules: Rule[]
  defaultResult: RuleResult
  version: number
}

export interface FlagDetail {
  flag: Flag
  /** Keyed by environment key. Archived environments are left out. */
  configs: Record<string, FlagConfig>
}

export type EvaluationContext = { targetingKey?: string } & Record<string, JSONValue>

export type Reason = 'STATIC' | 'TARGETING_MATCH' | 'SPLIT' | 'DEFAULT' | 'DISABLED' | 'ERROR'

export interface OFREPReply {
  status: number
  body: JSONValue
}

export interface DryRunResult {
  key: string
  reason: Reason
  value?: JSONValue
  variant?: string
  /** Index of the rule that matched; missing means the default. */
  matchedRule?: number
  errorCode?: string
  errorDetails?: string
  configVersion: number
  ofrep: OFREPReply
}

export interface BulkDryRunResult {
  flags: DryRunResult[]
  ofrep: OFREPReply
}

export type TokenKind = 'admin' | 'evaluation'

export interface Token {
  id: string
  kind: TokenKind
  scopes: string[]
  name: string
  environmentID?: string
  createdBy: string
  createdAt: string
  lastUsedAt?: string
  revokedAt?: string
}

export interface CreatedToken {
  token: Token
  secret: string
}

export interface AuditEntry {
  id: number
  timestamp: string
  actor: string
  action: string
  projectID?: string
  environmentID?: string
  flagKey?: string
  before?: JSONValue
  after?: JSONValue
}

export interface SeenContext {
  environmentID: string
  targetingKey: string
  firstSeen: string
  lastSeen: string
  attributes: Record<string, JSONValue>
}

export interface Exposure {
  environmentID: string
  targetingKey: string
  flagKey: string
  variant: string
  firstServed: string
  lastServed: string
  reason: Reason
  matchedRule?: number
  configVersion: number
}

export interface TrackedContextDetail {
  context: SeenContext
  exposures: Exposure[]
}

/** An admin API error: `{"error": "…", "issues": ["…"]}`, or a network failure (status 0). */
export class APIError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly issues: string[] = [],
  ) {
    super(message)
  }
}

type Query = Record<string, string | number | boolean | undefined>

/** Calls the admin API with `token`. Paths are relative to /admin/v1. */
export class AdminAPI {
  constructor(
    private readonly token: string,
    /** Called on `401`, so the app can send the user back to sign in. */
    private readonly onUnauthorized: () => void = () => {},
  ) {}

  private async request<T>(method: string, path: string, options: { query?: Query; body?: unknown } = {}): Promise<T> {
    const url = `/admin/v1/${path}${queryString(options.query ?? {})}`
    let response: Response
    try {
      response = await fetch(url, {
        method,
        headers: {
          Authorization: `Bearer ${this.token}`,
          ...(options.body === undefined ? {} : { 'Content-Type': 'application/json' }),
        },
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
      })
    } catch {
      throw new APIError(0, "Couldn't reach the server.")
    }
    if (response.status === 204) return undefined as T
    const text = await response.text()
    const json = text ? safeParse(text) : undefined
    if (!response.ok) {
      if (response.status === 401) this.onUnauthorized()
      const body = json as { error?: string; issues?: string[] } | undefined
      throw new APIError(response.status, body?.error ?? `${response.status} ${response.statusText}`, body?.issues ?? [])
    }
    return json as T
  }

  me() {
    return this.request<Token>('GET', 'me')
  }

  // Projects
  projects(includeArchived = false) {
    return this.request<Project[]>('GET', 'projects', { query: { includeArchived: includeArchived || undefined } })
  }
  createProject(key: string, name?: string) {
    return this.request<Project>('POST', 'projects', { body: { key, name: name || undefined } })
  }
  updateProject(project: string, changes: { key?: string; name?: string }) {
    return this.request<Project>('PATCH', `projects/${e(project)}`, { body: changes })
  }
  setProjectArchived(project: string, archived: boolean) {
    return this.request<Project>('POST', `projects/${e(project)}/${archived ? 'archive' : 'unarchive'}`)
  }

  // Environments
  environments(project: string, includeArchived = false) {
    return this.request<Environment[]>('GET', `projects/${e(project)}/environments`, {
      query: { includeArchived: includeArchived || undefined },
    })
  }
  createEnvironment(project: string, key: string, name?: string) {
    return this.request<Environment>('POST', `projects/${e(project)}/environments`, { body: { key, name: name || undefined } })
  }
  updateEnvironment(project: string, environment: string, changes: { key?: string; name?: string }) {
    return this.request<Environment>('PATCH', envPath(project, environment), { body: changes })
  }
  setEnvironmentArchived(project: string, environment: string, archived: boolean) {
    return this.request<Environment>('POST', `${envPath(project, environment)}/${archived ? 'archive' : 'unarchive'}`)
  }

  // Flags
  flags(project: string, includeArchived = false) {
    return this.request<Flag[]>('GET', `projects/${e(project)}/flags`, { query: { includeArchived: includeArchived || undefined } })
  }
  flag(project: string, flag: string) {
    return this.request<FlagDetail>('GET', flagPath(project, flag))
  }
  createFlag(
    project: string,
    body: { key: string; type: FlagType; variants: Record<string, JSONValue>; description?: string; isExperiment?: boolean; defaultVariant?: string },
  ) {
    return this.request<FlagDetail>('POST', `projects/${e(project)}/flags`, { body })
  }
  updateFlag(project: string, flag: string, changes: { description?: string; variants?: Record<string, JSONValue>; isExperiment?: boolean }) {
    return this.request<FlagDetail>('PATCH', flagPath(project, flag), { body: changes })
  }
  deleteFlag(project: string, flag: string) {
    return this.request<void>('DELETE', flagPath(project, flag))
  }
  setFlagArchived(project: string, flag: string, archived: boolean) {
    return this.request<FlagDetail>('POST', `${flagPath(project, flag)}/${archived ? 'archive' : 'unarchive'}`)
  }

  // Configs and dry runs
  setConfig(project: string, environment: string, flag: string, config: Omit<FlagConfig, 'version'>) {
    return this.request<FlagConfig>('PUT', `${envPath(project, environment)}/flags/${e(flag)}`, { body: config })
  }
  evaluate(project: string, environment: string, flag: string, context: EvaluationContext) {
    return this.request<DryRunResult>('POST', `${envPath(project, environment)}/flags/${e(flag)}/evaluate`, { body: { context } })
  }
  evaluateAll(project: string, environment: string, context: EvaluationContext) {
    return this.request<BulkDryRunResult>('POST', `${envPath(project, environment)}/evaluate`, { body: { context } })
  }

  // Tracking
  tracking(project: string, environment: string) {
    return this.request<TrackingSettings>('GET', `${envPath(project, environment)}/tracking`)
  }
  setTracking(project: string, environment: string, settings: TrackingSettings) {
    return this.request<TrackingSettings>('PUT', `${envPath(project, environment)}/tracking`, { body: settings })
  }
  trackedContexts(project: string, environment: string, query: { since?: string; limit?: number } = {}) {
    return this.request<SeenContext[]>('GET', `${envPath(project, environment)}/tracking/contexts`, { query })
  }
  trackedContext(project: string, environment: string, targetingKey: string) {
    return this.request<TrackedContextDetail>('GET', `${envPath(project, environment)}/tracking/context`, { query: { targetingKey } })
  }
  deleteTrackedContext(project: string, environment: string, targetingKey: string) {
    return this.request<void>('DELETE', `${envPath(project, environment)}/tracking/context`, { query: { targetingKey } })
  }
  exposures(
    project: string,
    environment: string,
    query: { targetingKey?: string; flag?: string; variant?: string; since?: string; limit?: number } = {},
  ) {
    return this.request<Exposure[]>('GET', `${envPath(project, environment)}/tracking/exposures`, { query })
  }

  // Tokens
  tokens() {
    return this.request<Token[]>('GET', 'tokens')
  }
  createToken(body: { name: string; kind: TokenKind; project?: string; environment?: string }) {
    return this.request<CreatedToken>('POST', 'tokens', { body })
  }
  revokeToken(id: string) {
    return this.request<Token>('POST', `tokens/${e(id)}/revoke`)
  }

  // Audit
  audit(query: { project?: string; flag?: string; actor?: string; since?: string; until?: string; limit?: number } = {}) {
    return this.request<AuditEntry[]>('GET', 'audit', { query })
  }
}

/**
 * `?a=1&b=2`, percent-encoded. Not URLSearchParams: it writes spaces as `+` (form encoding), and the server reads a
 * `+` as a plus, so a targeting key like "device 42" wouldn't be found.
 */
export function queryString(query: Query): string {
  const pairs = Object.entries(query)
    .filter(([, value]) => value !== undefined && value !== '')
    .map(([name, value]) => `${e(name)}=${e(String(value))}`)
  return pairs.length ? `?${pairs.join('&')}` : ''
}

const e = encodeURIComponent
const envPath = (project: string, environment: string) => `projects/${e(project)}/environments/${e(environment)}`
const flagPath = (project: string, flag: string) => `projects/${e(project)}/flags/${e(flag)}`

function safeParse(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}
