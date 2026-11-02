# WhatFeature

[![CI](https://github.com/junebash/WhatFeature/actions/workflows/ci.yml/badge.svg)](https://github.com/junebash/WhatFeature/actions/workflows/ci.yml)

A small feature flag service written in Swift. Flags are evaluated on the server and served over the [OpenFeature Remote Evaluation Protocol (OFREP)](https://github.com/open-feature/protocol), so any OpenFeature SDK with an OFREP provider can use it.

Status: early, but usable end to end: OFREP evaluation, an admin API and CLI, SQLite storage, tokens, and an audit log. No UI. Still to do for v1: a host. CI tests every push on Linux and macOS, and builds and starts the Docker image. The full list is under "Status and roadmap" in [`docs/DESIGN.md`](docs/DESIGN.md), along with the design and the full admin API.

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

Give an app its evaluation token:

```bash
swift run whatfeature tokens create --name "iOS app" -e dev
```

`login` saves the URL, token and project to `~/.config/whatfeature/config.json` (or under `$XDG_CONFIG_HOME`), readable only by you; `whatfeature logout` removes them.

`swift run whatfeature --help` lists every command, and every command has `--help`. Read commands take `--json`. The admin API underneath is documented in [`docs/DESIGN.md`](docs/DESIGN.md).

## Settings

Server:

| Option | Env | Default |
|---|---|---|
| `--database` | `DATABASE_PATH` | `whatfeature.sqlite` (`:memory:` for a throwaway database) |
| `--host` | `HOST` | `127.0.0.1` |
| `--port` | `PORT` | `8080` |
| `--seed` | `SEED_FILE` | none |
| `--admin-rate-limit` | `RATE_LIMIT_ADMIN` | `600` requests a minute per token (`off` to turn off) |

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

The live OFREP tests use [our fork of `swift-ofrep`](https://github.com/junebash/swift-ofrep), the server-side Swift OFREP provider: upstream can't send a token yet. See "Clients" in the design doc.
