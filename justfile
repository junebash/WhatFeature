# WhatFeature tasks. Run `just` to see them all.
#
# Needs Swift 6.2 or newer (Xcode 26 on a Mac). The docker-* recipes need Docker (Docker Desktop or OrbStack).

set shell := ["bash", "-euo", "pipefail", "-c"]

port := env("PORT", "8080")
url := "http://localhost:" + port
dev_db := "dev.sqlite"
# The evaluation token in examples/seed.json, for the demo project's dev environment. Local use only.
eval_token := "wf_eval_dev_local_only"

# List the recipes
default:
    @just --list --unsorted

# --- Development ---

# Build everything, tests included
build:
    swift build --build-tests

# Run every test
test:
    swift test

# Open the package in Xcode (macOS)
xcode:
    open Package.swift

# --- Try it locally, no Docker ---

# Create an admin token in the dev database and print it. Do this once, before `just serve`.
token name="dev":
    swift run --quiet whatfeature db token create --admin --name "{{name}}" --database {{dev_db}}

# Run the server on dev.sqlite, with the example project and flags loaded. Stop it with Ctrl-C.
serve:
    swift run whatfeature serve --database {{dev_db}} --seed examples/seed.json --port {{port}}

# Point the CLI at the local server (Docker or not) and save your admin token. It asks for the token.
login:
    swift run --quiet whatfeature login --url {{url}} --project demo

# Run any CLI command, e.g. `just cli flags list` or `just cli evaluate --all -e dev --targeting-key june`
[positional-arguments]
cli *args:
    swift run --quiet whatfeature "$@"

# What an app gets for every flag, asked the way an app asks (OFREP, with the dev evaluation token)
app-flags targeting_key="june":
    curl -fsS -X POST {{url}}/ofrep/v1/evaluate/flags \
        -H "Authorization: Bearer {{eval_token}}" \
        -H "Content-Type: application/json" \
        -d '{"context": {"targetingKey": "{{targeting_key}}"}}'
    @echo

# Check the server is answering
health:
    curl -fsS {{url}}/health
    @echo

# Delete the dev database. The next `just serve` starts fresh; make a new token with `just token` first.
reset:
    rm -f {{dev_db}} {{dev_db}}-shm {{dev_db}}-wal

# --- Docker ---

# Build the image
docker-build:
    docker build -t whatfeature .

# Run the image in the background, with its data in the whatfeature-data volume and the example flags loaded
docker-run:
    docker run -d --name whatfeature -p {{port}}:8080 \
        -v whatfeature-data:/data \
        -v "$PWD/examples:/seed:ro" -e SEED_FILE=/seed/seed.json \
        whatfeature
    @echo "Running on {{url}}. Next: just docker-token"

# Create an admin token inside the running container and print it
docker-token name="dev":
    docker exec whatfeature whatfeature db token create --admin --name "{{name}}"

# Follow the container's logs. Ctrl-C stops following, not the container.
docker-logs:
    docker logs -f whatfeature

# Stop and remove the container. Its data volume stays.
docker-stop:
    -docker rm -f whatfeature

# Stop the container and delete its data, for a fresh start
docker-reset: docker-stop
    -docker volume rm whatfeature-data
