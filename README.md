# WhatFeature

A small feature flag service written in Swift. Flags are evaluated on the server and served over the [OpenFeature Remote Evaluation Protocol (OFREP)](https://github.com/open-feature/protocol), so any OpenFeature SDK with an OFREP provider can use it.

Status: early, but usable end to end: OFREP evaluation, an admin API, SQLite storage, tokens, and an audit log. No UI. See [`docs/DESIGN.md`](docs/DESIGN.md) for the design and the full admin API.

## Try it

Needs Swift 6.2 or later. On Linux, also SQLite's development files (`apt install libsqlite3-dev`).

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

## Manage flags

Create an admin token once (it prints the secret):

```bash
swift run whatfeature token create --admin --name "June's laptop"
```

Then, with the server running (these examples use the seeded `demo` project) and the secret in `$ADMIN`:

```bash
curl -s -X POST localhost:8080/admin/v1/projects/demo/flags \
  -H "Authorization: Bearer $ADMIN" \
  -d '{"key": "dark-mode", "type": "boolean", "variants": {"on": true, "off": false}}'
```

New flags start disabled in every environment. Turn it on for 50% of users on app version 3.0 and up, in `dev`:

```bash
curl -s -X PUT localhost:8080/admin/v1/projects/demo/environments/dev/flags/dark-mode \
  -H "Authorization: Bearer $ADMIN" \
  -d '{"enabled": true,
       "rules": [{"conditions": [{"attribute": "appVersion", "operator": "semverGte", "value": "3.0"}],
                  "result": {"rollout": [{"variant": "on", "weight": 5000}, {"variant": "off", "weight": 5000}]}}],
       "defaultResult": {"variant": "off"}}'
```

Ask what a particular user would get, and why (`matchedRule` is the index of the rule that applied):

```bash
curl -s -X POST localhost:8080/admin/v1/projects/demo/environments/dev/flags/dark-mode/evaluate \
  -H "Authorization: Bearer $ADMIN" \
  -d '{"context": {"targetingKey": "user-123", "appVersion": "3.1"}}'
```

See who changed what:

```bash
curl -s "localhost:8080/admin/v1/audit?project=demo&flag=dark-mode" -H "Authorization: Bearer $ADMIN"
```

## Tokens

Secrets are printed once and only their hashes are stored. Besides `--admin`, the CLI can create evaluation tokens and list or revoke any token (the admin API's `/admin/v1/tokens` does the same):

```bash
swift run whatfeature token create --name "iOS app" --project demo --environment dev
```

```bash
swift run whatfeature token list
```

```bash
swift run whatfeature token revoke <token-id>
```

Revoking takes effect immediately, even while the server is running.

## Settings

| Option | Env | Default |
|---|---|---|
| `--database` | `DATABASE_PATH` | `whatfeature.sqlite` (`:memory:` for a throwaway database) |
| `--host` | `HOST` | `127.0.0.1` |
| `--port` | `PORT` | `8080` |
| `--seed` | `SEED_FILE` | none |

## Tests

```bash
swift test
```
