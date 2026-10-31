# WhatFeature

A small feature flag service written in Swift. Flags are evaluated on the server and served over the [OpenFeature Remote Evaluation Protocol (OFREP)](https://github.com/open-feature/protocol), so any OpenFeature SDK with an OFREP provider can use it.

Status: early. The OFREP endpoints work, backed by an in-memory store. There's no admin API or database yet. See [`docs/DESIGN.md`](docs/DESIGN.md).

## Try it

Needs Swift 6.2 or later.

```bash
swift run whatfeature serve --seed examples/seed.json
```

The seed file creates a `dev` environment, three flags, and the evaluation token `wf_eval_dev_local_only`. In another terminal:

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

Settings: `--host` / `HOST` (default `127.0.0.1`), `--port` / `PORT` (default `8080`), `--seed` / `SEED_FILE`.

## Tests

```bash
swift test
```
