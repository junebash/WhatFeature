# WhatFeature design

Status: most of v1 is built; see **Status and roadmap** near the end for what's done and what's left. This doc records the decisions. Anything under **Open questions** is not decided.

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
| Evaluation API | OFREP 0.4, with the JSON written by hand (see below for why) |
| Admin API | Our own REST API (OpenFeature doesn't define one) |
| Where rules run | Server only. Clients hold resolved values. |
| Storage | SQLite via [GRDB](https://github.com/groue/GRDB.swift). One database for everything. Evaluation goes through a small `EvaluationStore` protocol, so Postgres could replace SQLite later. |
| Tenancy | Projects, each with environments (e.g. `dev`, `prod`) |
| Flag types | boolean, string, number, object, with named variants |
| Targeting | Small custom rule model, built to be extended |
| Rollouts | Sticky percentage splits using a stable hash of the targeting key |
| Auth | Revocable, scoped bearer tokens for both admin and evaluation |
| Audit log | Yes, from v1 |
| Change updates | v1: ETag on bulk evaluation. v1.1: SSE `refetchEvaluation` events, as OFREP defines them |
| Evaluation contexts | Never stored, never logged |
| Deployment | Single container, config from env vars. Host not chosen yet. |
| License | MIT |

## Architecture

```
          apps (OpenFeature SDK + OFREP provider)        me (whatfeature CLI)
                         │                                     │
              POST /ofrep/v1/evaluate/...            /admin/v1/...
                         │                                     │
                ┌────────▼─────────────────────────────────────▼───────┐
                │  WhatFeatureServer (Hummingbird)                     │
                │  token middleware · rate limiter · routes            │
                └────────┬─────────────────────────────────┬───────────┘
                         │ read (hot path)                 │ write
                ┌────────▼──────────┐             ┌────────▼──────────┐
                │ snapshot cache    │◄── reload ──│ SQLiteStore       │
                │ (in-memory, per   │             │ (GRDB; behind     │
                │  environment)     │             │  EvaluationStore) │
                └────────┬──────────┘             └───────────────────┘
                         │
                ┌────────▼──────────┐
                │ WhatFeatureCore   │  pure Swift, no I/O:
                │ evaluation        │  models, rules, hashing
                └───────────────────┘
```

Evaluation never touches the database for flags. Each environment's flags are held in memory as an immutable snapshot with a version number. An admin write updates SQLite, then swaps in a new snapshot. A slow read can't overwrite a newer snapshot, because the cache keeps whichever version is higher.

Tokens are *not* cached: each request does one indexed lookup. So a token revoked from the CLI stops working immediately, even on a running server. Flags, on the other hand, should only be changed by the server process; another process writing flags to the same file wouldn't refresh the server's snapshots.

### Swift package layout

| Target | Kind | Contents |
|---|---|---|
| `WhatFeatureCore` | library | Models, rule types, evaluation (`EnvironmentSnapshot.evaluate`), bucketing hash, validation. No networking, no database. Most tests live here. |
| `WhatFeatureStorage` | library | `EvaluationStore` protocol, `SQLiteStore` (schema, migrations, snapshot cache, tokens, audit log), seed-file loading. Depends on Core. |
| `WhatFeatureAPI` | library | Admin API request/response types and `AdminPaths` (every path and query name), shared by server and client so they can't drift apart. |
| `WhatFeatureServer` | library | Hummingbird app, OFREP and admin routes, token middleware, ETags. |
| `WhatFeatureClient` | library | `AdminClient`: a typed client for the admin API (AsyncHTTPClient). |
| `whatfeature` | executable | The server (`serve`) and the admin CLI (see **CLI**). Migrations run automatically whenever the database opens. |

**Live tests.** Most server tests hand requests straight to the router (fast, no socket). These run a real server on a real port:

- `WhatFeatureClientTests`: the admin client, over HTTP.
- `WhatFeatureIntegrationTests`, OFREP: read by `swift-ofrep`, a real OpenFeature provider, so we find out if a real client disagrees with our hand-written JSON.
- `WhatFeatureIntegrationTests`, CLI: the built `whatfeature` binary, run as a separate process the way it's used from a terminal (`login`, a flag from creation to deletion, `evaluate --app-json`, failures). Each test gets an empty config directory and a clean environment. `swift test` builds the binary; the tests find it in `.build/debug` and run it with [swift-subprocess](https://github.com/swiftlang/swift-subprocess), which waits and reads output asynchronously, so no thread blocks.

## Data model

```
Project ──< Environment
   │
   └──< Flag ──< FlagConfig (one per environment)
                    └──< Rule ──< Condition

Token        (scoped to admin, or to one project + environment)
AuditEntry   (one per admin write)
```

In SQLite these are the tables `project`, `environment`, `flag`, `flagConfig`, `token` and `auditEntry`. A flag config's rules are stored as one JSON column rather than separate tables: they're nested and always read together, so splitting them up would only add joins.

Every flag has a config in every environment of its project. A new flag gets a **disabled** config everywhere, and a new environment gets a disabled config for every existing flag. So "is it on in prod?" never depends on whether someone remembered to create a config.

### Flag

Shared by every environment in a project.

- `key` — unique within the project, e.g. `new-onboarding`. Cannot change.
- `type` — `boolean | string | number | object`. **Cannot change after creation.** Make a new flag instead.
- `variants` — named values, e.g. `{ "on": true, "off": false }` or `{ "control": "blue", "test": "green" }`. Every value must match `type`.
- `description`
- `isExperiment` — marks the flag as an A/B test (assignment only for now). OFREP results for it carry `"metadata": {"experiment": true}`.
- `createdBy` (the actor, e.g. `token:<id>` or `system:seed`), `createdAt`
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
    var predicate: Predicate  // e.g. .version(.gte, 2.1.0)
}
```

OR logic comes from using several rules.

`Condition.Predicate` groups operators by the kind of value they compare, and each case carries a typed operand:

```swift
enum Predicate {
    case equality(Equality)                    // Equality(value, isEqual:)        → equals / notEquals
    case membership(Membership)                // Membership([values], isMember:)  → in / notIn
    case string(StringMatch)                   // StringMatch(.startsWith | .endsWith | .contains, string)
    case number(Comparison, Double)            // Comparison: .eq / .lt / .lte / .gt / .gte
    case version(Comparison, SemanticVersion)
    case presence(Presence)                    // Presence(isPresent:)             → exists / notExists
}
```

The JSON keeps one flat `operator` name (see the table below). Decoding goes through a private struct that mirrors the JSON, then converts it into a typed `Predicate`. A condition with the wrong operand type can't be decoded, so the admin API rejects it before it is saved.

These types are nested in `Condition` because Foundation has its own `Predicate` type.

Shorthands named after the JSON operators keep call sites short: `.equals("US")`, `.notIn(["DE", "FR"])`, `.startsWith("june@")`, `.exists`, and `RuleResult.rollout(["on": 1_000, "off": 9_000])` (ordered `KeyValuePairs`, because order decides the bucket ranges).

JSON shapes:

```json
{"attribute": "appVersion", "operator": "semverGte", "value": "2.1.0"}
{"variant": "on"}
{"rollout": [{"variant": "on", "weight": 1000}, {"variant": "off", "weight": 9000}]}
```

### Operators (v1)

| Group | Operators |
|---|---|
| Equality | `equals`, `notEquals`, `in`, `notIn` |
| Strings | `startsWith`, `endsWith`, `contains` |
| Numbers | `eq`, `lt`, `lte`, `gt`, `gte` |
| Semantic versions | `semverEq`, `semverLt`, `semverLte`, `semverGt`, `semverGte` |
| Presence | `exists`, `notExists` |

Rules:

- No regex operator yet. Swift's `Regex` isn't `Sendable`, so a compiled one can't live in a shared snapshot. `endsWith` covers the common case (email domains). We can add it later with a `Sendable` wrapper.
- **If the attribute is missing from the context (or `null`), the condition is false, whatever the operator.** The only exception is `notExists`. The principle: when we don't know, the rule doesn't fire, and evaluation falls through to later rules or the default. One consequence: `notIn` is not the same as "not `in`". `country notIn ["DE"]` does *not* match a context with no `country`. To match those as well, add a separate rule with `country notExists`.
- If the types don't match (e.g. `lt` on a string), the condition is false. It is not an error.
- Adding an operator means adding a case to `Condition.Operator` (the JSON name) and to `Predicate` (or one of its groups). The compiler then points at every `switch` that needs updating.
- **Individual targeting** ("put this user in the beta") is just `targetingKey in [...]`. Note that this stores user or device IDs inside the flag config. That is a deliberate choice, made per flag.

## Evaluation

```
evaluate(flagKey, context, environmentSnapshot):
  flag missing                 → error FLAG_NOT_FOUND
  flag archived or disabled    → reason DISABLED (app uses its code default)
  requested type ≠ flag type   → error TYPE_MISMATCH (only if the caller passes a type; OFREP never does)
  for rule in rules:
      if every condition matches:
          variant → value, reason TARGETING_MATCH
          rollout → bucket(...), reason SPLIT
  no rules at all              → defaultResult, reason STATIC
  no rule matched              → defaultResult, reason DEFAULT (or SPLIT if it's a rollout)
```

If a rollout needs a `targetingKey` and the context has none, that rule is skipped and evaluation moves on to the next one. If the *default* is a rollout, the result is error `TARGETING_KEY_MISSING`, and the app uses its own code default. Apps should always send a device ID, but we don't require it.

Results carry the index of the matched rule (or none for the default). The dry-run endpoint uses this to show *why* someone got a value.

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

Auth: `Authorization: Bearer wf_eval_…` or `X-API-Key: wf_eval_…` (OFREP allows both). The token decides which environment is used. A missing or unknown token gets `401`.

| Method | Path | Notes |
|---|---|---|
| `POST` | `/ofrep/v1/evaluate/flags/{key}` | Single flag. Body: `{ "context": { … } }` |
| `POST` | `/ofrep/v1/evaluate/flags` | All non-archived flags in the environment. Supports `If-None-Match` → `304`. |

Responses follow OFREP 0.4 (`service/openapi.yaml` in [open-feature/protocol](https://github.com/open-feature/protocol)):

| Outcome | Status | Body |
|---|---|---|
| Resolved | `200` | `key`, `value`, `variant`, `reason` (`STATIC`, `TARGETING_MATCH`, `SPLIT`, `DEFAULT`) |
| Disabled or archived | `200` | `key`, `reason: DISABLED`, **no `value`**. OFREP calls this a "code default" result: the app uses the default written in its code. |
| Flag not found | `404` | `key`, `errorCode: FLAG_NOT_FOUND`, `errorDetails` |
| Other error (e.g. `TARGETING_KEY_MISSING`) | `400` | `key`, `errorCode`, `errorDetails` |
| Unreadable body | `400` | `errorCode: PARSE_ERROR` (or `INVALID_CONTEXT` for valid JSON with a bad context), plus `key` on the single-flag endpoint |

In the bulk response, each flag is one of the first three shapes, sorted by key.

**Flag metadata.** Any result for a flag that exists (resolved, disabled, or an error like `TARGETING_KEY_MISSING`) can carry OFREP's `metadata`: a flat object of strings, numbers and booleans. OpenFeature SDKs pass it to hooks as flag metadata, so an exposure-logging hook can check `experiment` and log only A/B tests. `swift-ofrep` reads it.

- Today the only key is `experiment: true`, on flags marked `isExperiment`.
- Keys are only sent when they say something: other flags get no `metadata` at all, rather than `{"experiment": false}`. That keeps responses small and the common shapes unchanged. Hooks should treat a missing key as `false`.
- `FLAG_NOT_FOUND` has no flag, so no metadata.
- Changing `isExperiment` bumps the environment version, so the bulk ETag changes and cached clients see the new metadata.

Notes from reading the spec:

- **`DEFAULT` isn't in the spec's list of reasons**, but OpenFeature defines it and OFREP's own ADR-0006 example uses it. It looks like an oversight in the spec, so we send it.
- **There is no type in the request** (ADR-0003), so the server never returns `TYPE_MISMATCH`. The client SDK checks types.
- The JSON is **written by hand, not generated** with `swift-openapi-generator`. The spec's `allOf`/`oneOf` nesting turns into awkward generated types (`value1.value1.variant`), a generated reason enum would refuse `DEFAULT`, and there are only two endpoints. Tests pin the exact JSON shapes.

**ETag.** In flagd, the bulk ETag reflects only the flag config, so a client that changes its context must remember to drop its cached ETag. We avoid that trap by computing:

```
ETag = hash(environment config version + canonical JSON of the context)
```

A changed context or a changed flag produces a new ETag. We can answer `304` without evaluating anything. `If-None-Match` accepts `*`, lists, and weak (`W/`) tags.

Environment versions are stored in the database, so ETags stay valid across restarts. A throwaway `:memory:` database gets new environment IDs on every start, so its ETags never collide with older ones either.

### Admin (`/admin/v1`)

Auth: `Authorization: Bearer wf_admin_…` (or `X-API-Key`). A missing, unknown or revoked token gets `401`; an evaluation token gets `403`. Projects and environments are addressed by **key** in paths; tokens by ID.

| Method | Path | Body / query | Returns |
|---|---|---|---|
| `GET` / `POST` | `/projects` | `{key, name?}` | project(s) |
| `GET` | `/projects/{project}` | | project |
| `GET` / `POST` | `/projects/{project}/environments` | `{key, name?}` | environment(s) |
| `GET` | `/projects/{project}/flags` | `includeArchived=true`, `createdBy=token:<id>`, `sort=key\|createdAt`, `order=asc\|desc` | flags |
| `POST` | `/projects/{project}/flags` | `{key, type, variants, description?, isExperiment?, defaultVariant?}` | flag detail |
| `GET` | `/projects/{project}/flags/{flag}` | | flag detail |
| `PATCH` | `/projects/{project}/flags/{flag}` | any of `{description, variants, isExperiment}` | flag detail |
| `DELETE` | `/projects/{project}/flags/{flag}` | | `204` |
| `POST` | `/projects/{project}/flags/{flag}/archive`, `/unarchive` | | flag detail |
| `GET` / `PUT` | `/projects/{project}/environments/{env}/flags/{flag}` | a whole `FlagConfig` | config, with its new `version` |
| `POST` | `/projects/{project}/environments/{env}/flags/{flag}/evaluate` | `{context}` | **Dry run**: OFREP-style result plus `matchedRule` (missing means the default), `configVersion`, and `ofrep: {status, body}`, exactly what an app would get. Stores nothing. For "why did this user get that?" |
| `POST` | `/projects/{project}/environments/{env}/evaluate` | `{context}` | **Dry run of every flag**, like the bulk endpoint (archived flags left out): `{flags: [dry run…], ofrep: {status, body}}` |
| `GET` / `POST` | `/tokens` | `{name, kind: admin\|evaluation, project?, environment?}` | `{token, secret}`. The secret appears **only** in this response. Lists never show secrets or hashes. |
| `POST` | `/tokens/{id}/revoke` | | token |
| `GET` | `/audit` | `project=<key>`, `flag`, `actor`, `since` / `until` (ISO 8601), `limit` (1–1000, default 100) | entries, newest first, with `before`/`after` as JSON |

"Flag detail" is `{flag, configs}`, where `configs` maps each environment key to that environment's config. One call shows a flag's state everywhere.

Errors are `{"error": "…", "issues": ["…"]?}`: `400` for bad input (all validation problems at once, in `issues`), `404` for unknown keys, `409` for duplicate keys.

Every admin write checks its input first (variant values match the flag type, rules reference real variants, rollout weights add up to 10,000), then writes the change and its audit entry in **one transaction**. Changing a flag's variants re-checks every environment's config, so a variant still in use can't be removed.

**The dry run shows exactly what an app gets.** Its `ofrep` part is built by the same code as the OFREP endpoints (same evaluation call, same JSON encoder, same status), so it can't drift from them, and a test compares the two for every kind of result. It doesn't check an evaluation token: it answers for an environment, using your admin token.

Not yet: renaming or deleting projects and environments, and protection against two people editing the same config at once (an `If-Match` on the config version would do it).

**One definition of every path.** `AdminPaths` (in `WhatFeatureAPI`) builds each path. The server calls it with placeholders to register routes (`AdminPaths.flag(.project, .flag)` → `projects/{project}/flags/{flag}`); the client calls it with real keys. Query parameter names live there too. Client tests run every method and query parameter against a live server.

*Considered:* Point-Free's [swift-url-routing](https://github.com/pointfreeco/swift-url-routing), which makes one route enum that both parses requests and prints URLs. A spike with our 19 routes worked (every route round-tripped), but: the compiler crashed twice on valid router code ("failed to produce diagnostic"), case key paths had to be fully qualified, router types aren't `Sendable`, labeled enum payloads don't match, it adds 6 packages including swift-syntax, it's pre-1.0, and there's no Hummingbird integration. `AdminPaths` plus the live client tests get most of the benefit with none of that.

Plus `GET /admin/v1/me` (the token making the request; used by `whatfeature login` and `whoami`), and `GET /health` with no auth.

`POST …/flags` also takes an optional `defaultVariant`: what the new, disabled configs serve once someone enables them. Without it, that's the first variant name in sorted order (`off` for on/off flags). Environments created later always use the sorted-first rule.

## CLI

Every admin task has a command. They talk to a running server through the admin API, not to the database file, for three reasons:

1. The server only refreshes its in-memory snapshots for changes *it* makes. A CLI writing flags to the file would leave a running server serving stale values.
2. The server will usually run somewhere else. An HTTP CLI works from a laptop.
3. Changes are recorded in the audit log under your admin token.

The one exception is `whatfeature db token …`, which works on the file directly. It exists for the first admin token, which can't come from the API because nothing can call the API yet. Tokens aren't cached, so this is safe even while the server runs.

| Command | Does |
|---|---|
| `login` / `logout` / `whoami` | Save, forget, or show the server URL, admin token and default project |
| `projects list\|show\|create` | |
| `environments list\|create` (alias `envs`) | |
| `flags list\|show\|create\|update\|archive\|unarchive\|delete` | `show` gives the state in every environment; `delete` asks for confirmation |
| `config show\|set` | See or replace a whole config (JSON from a file, stdin, or `--json`) |
| `config enable\|disable` | Flip `enabled`, keeping the rules. `disable` is the kill switch. |
| `config serve <flag> <variant>` | Everyone gets one variant: clears rules, sets the default, enables |
| `config rollout <flag> on=10 off=90` | Percentage split of the default (two decimals allowed), keeping rules, and enables |
| `evaluate <flag>` / `evaluate --all` | The dry run: what a context gets and why, for one flag or all of them. `--app-json` prints exactly the JSON an app would get, and nothing else. |
| `tokens list\|create\|revoke` | Through the server |
| `audit` | Filters: project, flag, actor, since, until, limit |
| `db token create\|list\|revoke` | On the database file (bootstrap) |

Every read command takes `--json`.

Settings resolve flag → environment variable → `login` file: `--url` / `WHATFEATURE_URL`, `--token` / `WHATFEATURE_TOKEN`, `-p` / `WHATFEATURE_PROJECT`. `login` saves them to `$XDG_CONFIG_HOME/whatfeature/config.json` (else `~/.config/…`), created with `0600` permissions. If `login` gets no `--token`, it asks for one, so the secret stays out of shell history. (On macOS, the Keychain would be nicer; maybe later.)

Parsing rules worth knowing:

- **`--attr name=value` is always a string.** Otherwise `appVersion=2.0` would become the number 2.0 and silently stop matching semver rules. `--attr-json` is for typed values.
- **`--variant name=value` is read according to the flag's type**: `true`/`false` for booleans, plain text for strings, numbers for numbers, JSON for objects.

## Auth and tokens

- Format: `wf_admin_` or `wf_eval_`, then 43 random base62 characters (about 256 bits). The prefix makes leaked tokens easy to spot, and secret scanners can match it.
- Stored as SHA-256 of the secret. A slow password hash like bcrypt isn't needed, because these are long random strings, not human passwords.
- Fields: `id`, `hash`, `kind` (`admin` / `evaluation`), `scopes`, `environmentID?` (evaluation tokens only; the environment implies the project), `name`, `createdBy`, `createdAt`, `lastUsedAt`, `revokedAt`.
- `lastUsedAt` is written at most once a minute per token, so a busy app doesn't cause a database write per request.
- Revoking sets `revokedAt`. It works for every token, admin tokens included.
- **Evaluation tokens are public.** Anything shipped in an app binary can be pulled out of it. So they are read-only and limited to one project + environment.
- `scopes` is a list from the start, even though v1 only checks `admin` vs `evaluate`. Roles can be added later without a schema change.
- **Bootstrap:** run `whatfeature db token create --admin --name "June laptop"` on the server machine. It writes to the database file directly and prints the token once. From then on, the CLI's `tokens` commands (or `/admin/v1/tokens`) manage tokens through the server.

## Audit log

`AuditEntry`: `id`, `timestamp`, `actor`, `action` (e.g. `flag.create`, `flagConfig.update`, `token.revoke`), `projectID?`, `environmentID?`, `flagKey?`, `before` (JSON), `after` (JSON).

`actor` is `token:<id>` for changes made through the API, or `system:<name>` for the server itself (`system:seed`, `system:cli`).

Written in the same transaction as the change. Never edited or deleted through the API. Audit entries have no foreign keys, so they outlive whatever they describe. Token entries never include the secret or its hash.

## Privacy

Evaluation contexts can contain personal information (user IDs, emails). The server:

- uses the context to evaluate, then discards it
- never writes contexts to the database
- never logs context values. Request logs record the method and path only (for single-flag evaluation, the path includes the flag key).

The exception is individual targeting (see Operators). There, an ID I chose to put into a rule is stored in the flag config.

## Rate limiting

**Admin tokens: limited per token. Evaluation tokens: not limited by the server.** This follows what the big flag services do.

What they do (checked October 2026):

- **The client key is public and harmless.** LaunchDarkly, Unleash, Flagsmith and ConfigCat all treat client keys as public: read-only, one project and environment. Ours are the same (see **Auth and tokens**).
- **They don't throttle public keys one key at a time.** Flagsmith says its SDK endpoints aren't rate limited, only metered by plan, while its admin API is limited per user (that's from a preview build of their docs). ConfigCat serves client config from a CDN. Unleash points heavy client traffic at Unleash Edge, a proxy.
- **The reason:** one public key is shared by every install. A limit on that key lets one buggy device, or anyone who pulls the key out of the app, get *every* install a `429`, and they all fall back to code defaults. That's worse than the load it saves. Our evaluation is cheap anyway: rules run in memory, and `304`s skip evaluation entirely.
- **Abuse is handled elsewhere:** by client IP in a CDN or proxy in front of the server, by rotating a key that gets abused, and (for stronger protection) by app attestation such as Firebase App Check with Apple's App Attest.

So:

- **Admin tokens:** an in-memory token bucket per token, 600 requests a minute by default (`serve --admin-rate-limit` / `RATE_LIMIT_ADMIN`; a whole number, or `off`). The bucket holds one minute's worth, so that's up to 600 at once, then 10 a second. In-memory works because there is a single instance.
  - **Checked after the token.** Only real tokens get a bucket (keyed by the token's hash), so made-up tokens can't fill memory. They get `401` as before.
  - **Over the limit → `429`** with `Retry-After` in whole seconds and `{"error": "Too many requests. Try again in N seconds."}`. Logged at `notice` with the token ID, never the secret.
- **Evaluation tokens: the server never limits them.** **Per-IP limits belong in the proxy in front of the server** (e.g. Cloudflare rate-limiting rules if we use Cloudflare Tunnel). Decide when the host is chosen. An abused token gets revoked and replaced (`whatfeature tokens revoke`).

*Considered:* an opt-in per-token evaluation limit. It was built, then removed: it's the very thing the services above avoid, and it would likely never be turned on. If it's ever needed, it's in the git history (commit `364e653`). Note for that day: OFREP's spec gives `Retry-After` as an ISO 8601 date, and `swift-ofrep` can't read plain seconds.

## Deployment

Not chosen yet. Constraints that keep every option open:

- one Docker image, Linux, all config from environment variables
- runs as a single instance, with SQLite on a persistent disk
- **SSE (v1.1) needs a long-lived process.** Hosts that scale to zero, or bill for open connections, get worse once streaming arrives.

Candidates to price out: Fly.io, Oracle Cloud's free tier, Google Cloud Run (needs a fix for SQLite on its temporary disk, e.g. Litestream), or hardware at home behind Cloudflare Tunnel.

## Status and roadmap

CI (`.github/workflows/ci.yml`) runs `swift test` on every push to `main` and on pull requests, on Linux (the `swift:6.4.2-noble` container, where the server runs) and macOS (the `macos-26` image's default Xcode, where the CLI and development run).

### Done

- **Core:** flag model, typed rules and operators, semver, sticky SHA-256 bucketing, evaluation with OFREP reasons, validation.
- **OFREP:** single and bulk evaluation, bearer or `X-API-Key` tokens, ETag / `304`, disabled flags as "code default" results.
- **Storage:** SQLite (GRDB) with migrations, an in-memory snapshot cache, revocable hashed tokens, an audit log written in the same transaction as each change, and an idempotent seed file (`examples/seed.json`).
- **Admin API:** projects, environments, flags (create, update, archive, delete), per-environment configs, dry-run evaluation, tokens, audit log, `me`.
- **CLI:** every admin task, through the admin API (see **CLI**), plus `db token` for bootstrapping.
- **A/B assignment:** sticky rollouts, plus the `isExperiment` marker on flags, sent to apps as OFREP flag metadata (`"experiment": true`).
- **CI:** `swift test` on Linux and macOS.
- **Rate limiting:** per admin token, `429` with `Retry-After`. Evaluation tokens are left to a proxy, like the big flag services do (see **Rate limiting**).

### Left for v1

1. **Dockerfile.** Docker isn't available in the dev container, so it needs a first build on a Mac. The official Swift images lack SQLite's headers: the build stage needs `libsqlite3-dev` (as in CI), the run stage `libsqlite3-0`.
2. **Pick a host and deploy.** See **Deployment** and **Open questions**.
3. **Try it on a Mac by hand.** CI builds and tests on macOS, but nobody has opened the package in Xcode or used the CLI from a Mac yet.

### Known gaps (fine for now; fix if they start to hurt)

- Projects and environments can't be renamed or deleted.
- No protection against two edits to the same config at once. An `If-Match` on the config version would do it.
- Environments created *after* a flag get the sorted-first variant as their default, even if the flag was created with `--default`.
- The CLI keeps its admin token in a `0600` file. The macOS Keychain would be better there.
- No regex operator (see **Operators**).
- Nothing limits evaluation requests, or requests without a valid token, until a proxy in front of the server limits by IP (see **Rate limiting**). That waits on the host.
- Integer vs. float numbers (see **Open questions**).

### Later

| Version | Scope |
|---|---|
| **v1.1** | SSE, as OFREP defines it (ADR-0008): the bulk response gets an `eventStreams` entry pointing at our SSE endpoint, which sends `{"type": "refetchEvaluation", "etag": …}` when config changes. Clients re-fetch the bulk endpoint. No custom extension needed. Also experiment exposure tracking, lined up with OpenFeature's tracking API. |
| **v1.5** | Support tooling: look up "what has this user been getting" and opt them into betas easily. Needs a careful decision about what gets stored (see **Privacy**). |
| **later** | App attestation (Apple's App Attest) for evaluation requests, UI, scheduled flag changes, flag dependencies, admin roles, Postgres store, experiment analysis |

## Open questions

1. **Hosting** (see **Deployment**). The cheapest option that keeps a long-lived process (needed for SSE in v1.1) wins.
2. **Integer vs. float.** OFREP has separate integer and float value types; we have one `number`. JSON can't tell `0` from `0.0`, so a whole-number value always goes out as an integer. Upstream `swift-ofrep` then gave `TYPE_MISMATCH` to an app asking for a `Double`; our fork accepts it (live test `wholeNumberAsDouble`). Asking for an `Int` and getting `2.5` is still a mismatch, which is right. Leaning towards keeping one `number` type. Other clients (the iOS SDK's OFREP provider) aren't checked yet.

## Clients

- **Server-side Swift:** [`swift-ofrep`](https://github.com/swift-open-feature/swift-ofrep) (built on `swift-open-feature`) uses the single-flag endpoint. **Upstream doesn't work with WhatFeature; use [our fork](https://github.com/junebash/swift-ofrep)**, which the live tests also use. Upstream (7 stars, no releases, last code change March 2025) has four problems the fork fixes:
  1. **No way to send a token.** The fork adds `OFREPProvider(serverURL:headerFields:)`, e.g. `headerFields: [.authorization: "Bearer wf_eval_…"]`.
  2. **It doesn't build** against current `swift-open-feature`, which made Service Lifecycle an opt-in trait.
  3. **It predates OFREP's "code default" result** (August 2025), so a disabled flag came back as an error instead of the app's default.
  4. **A whole number asked for as a `Double`** (e.g. `0`) was a type mismatch. JSON has one number type, so that's a valid `Double`.

  Each is its own commit, ready to offer upstream as a pull request.
- **iOS / Apple platforms:** the OpenFeature Swift SDK ([open-feature/swift-sdk](https://github.com/open-feature/swift-sdk)) with an OFREP provider for static contexts. That provider uses the bulk endpoint. One exists in go-feature-flag's Swift provider; check whether it is usable on its own.
