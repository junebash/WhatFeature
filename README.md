# WhatFeature

[![CI](https://github.com/junebash/WhatFeature/actions/workflows/ci.yml/badge.svg)](https://github.com/junebash/WhatFeature/actions/workflows/ci.yml)

A small feature flag service written in Swift. Flags are evaluated on the server and served over the [OpenFeature Remote Evaluation Protocol (OFREP)](https://github.com/open-feature/protocol), so any OpenFeature SDK with an OFREP provider can use it. Swift apps can use the small `WhatFeatureFlags` library instead (see "Use flags in an app" below).

Status: early, but usable end to end: OFREP evaluation, an admin API and CLI, SQLite storage, tokens, an audit log, and optional tracking of who was served what. No UI. Deploys to Railway (see below). CI tests every push on Linux and macOS, and builds and starts the Docker image. The full list is under "Status and roadmap" in [`docs/DESIGN.md`](docs/DESIGN.md), along with the design and the full admin API.

## Try it

Needs Swift 6.2 or later. On Linux, also SQLite's development files (`apt install libsqlite3-dev`).

The quickest way is the [`justfile`](justfile) (`brew install just`; run `just` to list the recipes):

```bash
just token
```

```bash
just serve
```

```bash
just login
```

`just token` prints an admin token for `dev.sqlite`; `just serve` runs the server on it with the example flags; `just login` (in another terminal) asks for the token and saves it, so `just cli flags list` and the rest work. `just app-flags` shows what an app gets. `just reset` starts over.

Or by hand:

```bash
swift run whatfeature serve --seed examples/seed.json
```

This creates `whatfeature.sqlite` in the current folder (or pass `--database :memory:` for a throwaway one). The seed file adds a `demo` project with `dev` and `prod` environments, three flags, and the evaluation token `wf_eval_dev_local_only`. Loading it again changes nothing, so it's fine to leave `--seed` on.

In another terminal:

```bash
curl -s -X POST localhost:8080/ofrep/v1/evaluate/flags/new-onboarding \
  -H "Authorization: Bearer wf_eval_dev_local_only" \
  -d '{"context": {"targetingKey": "user-123", "country": "US"}}'
```

```json
{"key": "new-onboarding", "value": true, "variant": "on", "reason": "TARGETING_MATCH"}
```

Every flag at once (send the returned `ETag` back as `If-None-Match` to get `304` when nothing changed):

```bash
curl -s -i -X POST localhost:8080/ofrep/v1/evaluate/flags \
  -H "Authorization: Bearer wf_eval_dev_local_only" \
  -d '{"context": {"targetingKey": "user-123", "appVersion": "2.1"}}'
```

### Docker

```bash
just docker-build
```

```bash
just docker-run
```

```bash
just docker-token
```

The image runs the server on port 8080, with its SQLite database on the `/data` volume (`whatfeature-data` in the recipe). Settings are the environment variables below; `HOST`, `PORT` and `DATABASE_PATH` are already set for the container. `just docker-token` creates an admin token inside the running container; then `just login` works the same as without Docker. `just docker-reset` deletes the container and its data.

### Deploy to Railway

Any host that runs a Docker image as **one** always-on instance, with a persistent disk at `/data`, will do. Ours is [Railway](https://railway.com): one service built from the `Dockerfile`, in one region, with a volume at `/data`. Needs the [Railway CLI](https://docs.railway.com/cli), logged in (`railway login`).

```bash
railway init --name whatfeature
railway add --service whatfeature --variables RAILWAY_RUN_UID=0 --variables PORT=8080
# Pick the service's region in its settings now: a volume stays in the region it was created in.
railway volume add --mount-path /data
railway service source connect --repo <owner>/WhatFeature --branch main --service whatfeature
railway domain --port 8080
just railway-token     # prints an admin token from the server
just cli login --url https://<your-domain>
```

`RAILWAY_RUN_UID=0` runs the server as root, because Railway mounts volumes as root and the image's own user can't write to them. In the service's settings, set the health check path to `/health` and turn on **Wait for CI**, so a push to `main` deploys only once CI passes. Other settings (such as `RATE_LIMIT_ADMIN`) are service variables. Deploying again keeps the data; the server is down for a few seconds while it restarts. Tracking data, if you turn it on, goes in `/data/whatfeature-tracking.sqlite` on the same volume.

Prebuilt CLI binaries for Linux (x86_64, static, no dependencies) and macOS are on the [releases page](https://github.com/junebash/WhatFeature/releases). To cut one: `just release 0.1.0`.

## Manage flags

Everything has a CLI command. The CLI talks to the server's admin API, so it works the same against a server on your laptop or somewhere else.

Create the first admin token on the machine with the database (it prints the secret once):

```bash
swift run whatfeature db token create --admin --name "June's laptop"
```

Save it, with a default project, so you don't have to pass them every time. Leave out `--token` and it asks, which keeps the secret out of your shell history:

```bash
swift run whatfeature login --url http://127.0.0.1:8080 --project demo
```

Create a flag. It starts disabled in every environment:

```bash
swift run whatfeature flags create dark-mode --description "Dark mode beta"
```

Roll it out to 10% in `dev`:

```bash
swift run whatfeature config rollout dark-mode on=10 off=90 -e dev
```

See it everywhere at once:

```bash
swift run whatfeature flags show dark-mode
```

Ask what a particular user would get, and why:

```bash
swift run whatfeature evaluate dark-mode -e dev --targeting-key user-123 --attr appVersion=3.1
```

Or every flag at once, and exactly the JSON the app would get:

```bash
swift run whatfeature evaluate --all -e dev --targeting-key user-123
```

```bash
swift run whatfeature evaluate --all -e dev --targeting-key user-123 --app-json
```

Turn it off (the kill switch):

```bash
swift run whatfeature config disable dark-mode -e dev
```

See who changed what:

```bash
swift run whatfeature audit --flag dark-mode
```

Record who gets what (off by default; see "Tracking" in [`docs/DESIGN.md`](docs/DESIGN.md)), then look:

```bash
swift run whatfeature tracking set -e dev --on --attributes appVersion
swift run whatfeature tracking contexts -e dev
swift run whatfeature tracking context user-123 -e dev
swift run whatfeature tracking exposures -e dev --flag dark-mode --json
```

Tracking stores user or device IDs, which count as personal data under GDPR and similar laws, so say so in your privacy policy before turning it on in production. Only the targeting key and the attributes you list are kept, for 30 days after an ID was last seen (`--retention-days` to change). `whatfeature tracking delete <id> -e <env>` removes one ID's data. An "exposure" means the server sent that variant to that ID, not that the user saw the feature.

Give an app its evaluation token:

```bash
swift run whatfeature tokens create --name "iOS app" -e dev
```

`login` saves the URL and project to `~/.config/whatfeature/config.json` (or under `$XDG_CONFIG_HOME`), readable only by you. The token goes in the Keychain on macOS, and in that file elsewhere (or with `WHATFEATURE_KEYCHAIN=off`). `whatfeature logout` removes them.

`swift run whatfeature --help` lists every command, and every command has `--help`. Read commands take `--json`. The admin API underneath is documented in [`docs/DESIGN.md`](docs/DESIGN.md).

## Use flags in an app

Add this package with its default trait off, so you fetch only what the client needs (swift-crypto), not the server's dependencies:

```swift
.package(url: "https://github.com/junebash/WhatFeature.git", branch: "main", traits: []),
// in your target:
.product(name: "WhatFeatureFlags", package: "WhatFeature"),
```

 It needs only Foundation (and swift-crypto), so it works in iOS apps (iOS 18+) and server-side Swift:

```swift
import WhatFeatureCore
import WhatFeatureFlags

let client = FlagClient(baseURL: URL(string: "https://flags.example.com")!, token: "wf_eval_…", session: .shared)
let context = EvaluationContext(targetingKey: userID, attributes: ["appVersion": "2.1"])
var flags = try await client.fetch(context: context)

if flags.bool("new-onboarding", default: false) { … }
let greeting = flags.string("greeting", default: "Hello")

// Later: cheap when nothing changed (the server answers 304 and you get `flags` back).
flags = try await client.fetch(context: context, previous: flags)
```

Every getter takes your default and returns it when the flag is off, missing, or of another type.

To have values at launch and offline, give the client a cache. Every successful fetch is saved, and the next launch starts from the saved flags (and gets a cheap `304` if nothing changed):

```swift
let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
let client = FlagClient(baseURL: url, token: "wf_eval_…", session: .shared, cache: FlagCache(directory: caches.appending(path: "WhatFeature")))

var flags = client.cachedFlags(for: context) ?? Flags(flags: [])  // right away, no network
flags = try await client.fetch(context: context)                   // then fresh values, saved for next time
```

## Settings

Server:

| Option | Env | Default |
|---|---|---|
| `--database` | `DATABASE_PATH` | `whatfeature.sqlite` (`:memory:` for a throwaway database) |
| `--host` | `HOST` | `127.0.0.1` |
| `--port` | `PORT` | `8080` |
| `--seed` | `SEED_FILE` | none |
| `--admin-rate-limit` | `RATE_LIMIT_ADMIN` | `600` requests a minute per token (`off` to turn off) |
| `--tracking-database` | `TRACKING_DATABASE_PATH` | next to `--database`, with `-tracking` added (`whatfeature-tracking.sqlite`). Only written for environments with tracking on; see "Tracking" in [`docs/DESIGN.md`](docs/DESIGN.md). |

CLI (flag, else env, else what `login` saved):

| Option | Env |
|---|---|
| `--url` | `WHATFEATURE_URL` |
| `--token` | `WHATFEATURE_TOKEN` |
| `-p` / `--project` | `WHATFEATURE_PROJECT` |

## Tests

```bash
swift test
```

The live tests run a real server on a real port and read it with the admin client, the `whatfeature` binary, and `FlagClient`.
