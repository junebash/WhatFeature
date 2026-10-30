# WhatFeature design

Status: draft. This records the decisions made so far. Anything under **Open questions** is not decided.

## Goal

A feature flag service for my own apps. I create flags and set rules. Apps and services ask "what is this flag for this user/device?" and get an answer.

It is also a learning project: the point is to understand how a flag service works inside, in a language I know well. Simple and readable beats clever.

### Non-goals (for now)

- A UI. Everything is REST.
- Client-side evaluation. Rules never leave the server.
- Experiment analysis (did variant B win?).
- Multiple instances / high availability.

## Decisions at a glance

| Topic | Decision |
|---|---|
| Language / framework | Swift 6, Hummingbird 2 (latest) |
| Evaluation API | OFREP, generated from its OpenAPI spec with `swift-openapi-generator` |
| Admin API | Our own REST API (OpenFeature doesn't define one) |
| Where rules run | Server only. Clients hold resolved values. |
| Storage | SQLite behind a `FlagStore` protocol, so Postgres can replace it later. One database for everything. |
| Tenancy | Projects, each with environments (e.g. `dev`, `prod`) |
| Flag types | boolean, string, number, object, with named variants |
| Targeting | Small custom rule model, built to be extended |
| Rollouts | Sticky percentage splits using a stable hash of the targeting key |
| Auth | Revocable, scoped bearer tokens for both admin and evaluation |
| Audit log | Yes, from v1 |
| Change updates | v1: ETag on bulk evaluation. v1.1: SSE "config changed" events |
| Evaluation contexts | Never stored, never logged |
| Deployment | Single container, config from env vars. Host not chosen yet. |
| License | MIT |

## Architecture

```
          apps (OpenFeature SDK + OFREP provider)        me (curl / scripts)
                         │                                     │
              POST /ofrep/v1/evaluate/...            /admin/v1/...
                         │                                     │
                ┌────────▼─────────────────────────────────────▼───────┐
                │  WhatFeatureServer (Hummingbird)                     │
                │  auth middleware · rate limiter · routes             │
                └────────┬─────────────────────────────────┬───────────┘
                         │ read (hot path)                 │ write
                ┌────────▼──────────┐             ┌────────▼──────────┐
                │ ConfigCache       │◄── reload ──│ FlagStore         │
                │ (in-memory, per   │             │ (protocol;        │
                │  environment)     │             │  SQLite impl)     │
                └────────┬──────────┘             └───────────────────┘
                         │
                ┌────────▼──────────┐
                │ WhatFeatureCore   │  pure Swift, no I/O:
                │ Evaluator         │  models, rules, hashing
                └───────────────────┘
```

Evaluation never touches the database. Each environment's flag config is held in memory as an immutable snapshot with a version number. An admin write updates SQLite, then swaps in a new snapshot.

### Swift package layout

| Target | Kind | Contents |
|---|---|---|
| `WhatFeatureCore` | library | Models, rule types, `Evaluator`, bucketing hash. No networking, no database. Most tests live here. |
| `WhatFeatureStorage` | library | `FlagStore` protocol and the SQLite implementation |
| `WhatFeatureServer` | library | Hummingbird app, routes, middleware, OFREP generated code |
| `whatfeature` | executable | CLI: `serve`, `token create`, `migrate` |

## Data model

```
Project ──< Environment
   │
   └──< Flag ──< FlagConfig (one per environment)
                    └──< Rule ──< Condition

Token        (scoped to admin, or to one project + environment)
AuditEntry   (one per admin write)
```

### Flag

Shared by every environment in a project.

- `key` — unique within the project, e.g. `new-onboarding`. Cannot change.
- `type` — `boolean | string | number | object`. **Cannot change after creation.** Make a new flag instead.
- `variants` — named values, e.g. `{ "on": true, "off": false }` or `{ "control": "blue", "test": "green" }`. Every value must match `type`.
- `description`
- `isExperiment` — marks the flag as an A/B test (assignment only for now)
- `createdBy` (token ID), `createdAt`
- `archivedAt` — archived flags are hidden from listings by default and evaluate as `DISABLED`

### FlagConfig (per environment)

- `enabled` — when `false`, evaluation returns reason `DISABLED` and the app uses its code default
- `rules` — ordered list. The first matching rule wins.
- `defaultResult` — used when no rule matches
- `version` — goes up on every change

### Rule

```swift
struct Rule {
    var conditions: [Condition]   // all must match (AND); empty means always match
    var result: RuleResult
}

enum RuleResult {
    case variant(String)                  // e.g. "on"
    case rollout([WeightedVariant])       // e.g. 10% "on", 90% "off"
}

struct Condition {
    var attribute: String     // context key, e.g. "appVersion", "targetingKey"
    var op: Operator
    var value: ContextValue
}
```

OR logic comes from using several rules.

### Operators (v1)

| Group | Operators |
|---|---|
| Equality | `equals`, `notEquals`, `in`, `notIn` |
| Strings | `startsWith`, `endsWith`, `contains`, `matches` (regex) |
| Numbers | `lt`, `lte`, `gt`, `gte` |
| Semantic versions | `semverEq`, `semverLt`, `semverLte`, `semverGt`, `semverGte` |
| Presence | `exists`, `notExists` |

Rules:

- **If the attribute is missing from the context, the condition is false, whatever the operator.** The only exception is `notExists`. The principle: when we don't know, the rule doesn't fire, and evaluation falls through to later rules or the default. One consequence: `notIn` is not the same as "not `in`". `country notIn ["DE"]` does *not* match a context with no `country`. To match those as well, add a separate rule with `country notExists`.
- If the types don't match (e.g. `lt` on a string), the condition is false. It is not an error.
- `Operator` is a Swift enum. Adding one means adding a case and its implementation, and the compiler shows every place that needs updating.
- **Individual targeting** ("put this user in the beta") is just `targetingKey in [...]`. Note that this stores user or device IDs inside the flag config. That is a deliberate choice, made per flag.

## Evaluation

```
evaluate(flagKey, context, environmentSnapshot):
  flag missing                 → error FLAG_NOT_FOUND
  flag archived or disabled    → reason DISABLED (app uses its code default)
  requested type ≠ flag type   → error TYPE_MISMATCH (when the request says which type)
  for rule in rules:
      if every condition matches:
          variant → value, reason TARGETING_MATCH
          rollout → bucket(...), reason SPLIT
  no rule matched              → defaultResult, reason DEFAULT (or SPLIT if it's a rollout)
```

If a rollout needs a `targetingKey` and the context has none, that rule is skipped. If the default result is the rollout, we fall back to the first variant in it, with error code `TARGETING_KEY_MISSING`. Apps should always send a device ID, but we don't require it.

### Bucketing (how rollouts stay sticky)

```
bucket = first 8 bytes of SHA-256("\(flagKey)/\(targetingKey)") as UInt64, mod 10_000
```

That gives a number from 0 to 9,999, in hundredths of a percent. Variants take ranges in order: a 10/90 split of `on`/`off` means buckets 0–999 get `on`.

- **Why not Swift's `hashValue`?** `Hasher` is seeded randomly for each process, so the same user would get a different bucket after every server restart.
- **Why include the flag key?** Otherwise the same 10% of users would be first in line for every rollout.
- **Raising a two-variant rollout from 10% to 20% keeps the original 10%**, because their buckets (0–999) are still inside the new range (0–1,999). With three or more variants, changing the weights *can* move people between variants. Worth knowing for experiments: don't re-weight a running A/B test.

## API

### Evaluation (OFREP)

Auth: `Authorization: Bearer wf_eval_…`. The token decides which project and environment are used.

| Method | Path | Notes |
|---|---|---|
| `POST` | `/ofrep/v1/evaluate/flags/{key}` | Single flag. Body: `{ "context": { … } }` |
| `POST` | `/ofrep/v1/evaluate/flags` | All non-archived flags in the environment. Supports `If-None-Match` → `304`. |

Responses follow OFREP: `key`, `value`, `reason`, `variant`, `metadata`, or `errorCode` + `errorDetails`.

**ETag.** In flagd, the bulk ETag reflects only the flag config, so a client that changes its context must remember to drop its cached ETag. We avoid that trap by computing:

```
ETag = hash(environment config version + canonical JSON of the context)
```

A changed context or a changed flag produces a new ETag. We can answer `304` without evaluating anything.

### Admin (`/admin/v1`)

Auth: `Authorization: Bearer wf_admin_…`

| Method | Path | Notes |
|---|---|---|
| `GET` / `POST` | `/projects` | |
| `GET` / `PATCH` / `DELETE` | `/projects/{project}` | |
| `GET` / `POST` | `/projects/{project}/environments` | |
| `GET` / `POST` | `/projects/{project}/flags` | List filters: `createdBy`, `includeArchived`. Sort: `createdAt`, `key`. |
| `GET` / `PATCH` / `DELETE` | `/projects/{project}/flags/{key}` | Edit description, variants (type stays fixed) |
| `POST` | `/projects/{project}/flags/{key}/archive` and `/unarchive` | |
| `GET` / `PUT` | `/projects/{project}/environments/{env}/flags/{key}` | That environment's config: enabled, rules, default |
| `POST` | `/projects/{project}/environments/{env}/flags/{key}/evaluate` | **Dry run.** "What does this user get, and why?" Returns the matched rule index too. Stores nothing. For support questions. |
| `GET` / `POST` | `/tokens` | Creating a token returns the secret **once** |
| `POST` | `/tokens/{id}/revoke` | |
| `GET` | `/audit` | Filters: project, flag, actor, time range |

Plus `GET /health` with no auth.

Every admin write checks its input first (variant values match the flag type, rules reference real variants, rollout weights add up to 10,000), then writes the change and its audit entry in **one transaction**.

## Auth and tokens

- Format: `wf_admin_<32 random bytes, base62>` or `wf_eval_<…>`. The prefix makes leaked tokens easy to spot, and secret scanners can match it.
- Stored as SHA-256 of the secret. A slow password hash like bcrypt isn't needed, because these are long random strings, not human passwords.
- Fields: `id`, `hash`, `kind` (`admin` / `evaluation`), `scopes`, `projectID?`, `environmentID?`, `name`, `createdBy`, `createdAt`, `lastUsedAt`, `revokedAt`.
- Revoking sets `revokedAt`. It works for every token, admin tokens included.
- **Evaluation tokens are public.** Anything shipped in an app binary can be pulled out of it. So they are read-only and limited to one project + environment.
- `scopes` is a list from the start, even though v1 only checks `admin` vs `evaluate`. Roles can be added later without a schema change.
- **Bootstrap:** run `whatfeature token create --admin --name "June laptop"` on the server. It prints the token once.

## Audit log

`AuditEntry`: `id`, `timestamp`, `actorTokenID`, `action` (e.g. `flag.create`, `flagConfig.update`, `token.revoke`), `projectID?`, `environmentID?`, `flagKey?`, `before` (JSON), `after` (JSON).

Written in the same transaction as the change. Never edited or deleted through the API.

## Privacy

Evaluation contexts can contain personal information (user IDs, emails). The server:

- uses the context to evaluate, then discards it
- never writes contexts to the database
- never logs context values. Request logs record the token ID, flag key, and result reason only.

The exception is individual targeting (see Operators). There, an ID I chose to put into a rule is stored in the flag config.

## Rate limiting

An in-memory token bucket for each token. Over the limit → `429` with `Retry-After`, as OFREP specifies. This works because there is a single instance.

## Deployment

Not chosen yet. Constraints that keep every option open:

- one Docker image, Linux, all config from environment variables
- runs as a single instance, with SQLite on a persistent disk
- **SSE (v1.1) needs a long-lived process.** Hosts that scale to zero, or bill for open connections, get worse once streaming arrives.

Candidates to price out: Fly.io, Oracle Cloud's free tier, Google Cloud Run (needs a fix for SQLite on its temporary disk, e.g. Litestream), or hardware at home behind Cloudflare Tunnel.

## Roadmap

| Version | Scope |
|---|---|
| **v1** | Everything above: OFREP single + bulk with ETag, admin API, rules, rollouts, A/B assignment (`isExperiment`), tokens, audit log, dry-run evaluate |
| **v1.1** | SSE stream at `/ofrep/v1/events` (our own extension, not part of OFREP). It sends a small `configChanged` event with the new version. Clients re-fetch the bulk endpoint with their ETag. Requires our own client provider, or an extension to `swift-ofrep`. Experiment exposure tracking, lined up with OpenFeature's tracking API. |
| **v1.5** | Support tooling: look up "what has this user been getting" and opt them into betas easily. Needs a careful decision about what gets stored (see Privacy). |
| **later** | UI, scheduled flag changes, flag dependencies, admin roles, Postgres store, experiment analysis |

## Open questions

1. Hosting (see Deployment).
2. SQLite library: GRDB (mature, works on Linux) or `sqlite-nio` (async, NIO-based). Leaning GRDB. To decide while scaffolding.
3. Does `swift-ofrep` send a type hint with its requests? That decides whether `TYPE_MISMATCH` can be checked on the server or only in the client SDK.
