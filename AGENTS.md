# Agent guidelines

## Workflow

This repo uses trunk-based development.

- Commit straight to `main` and push. No feature branches or pull requests needed.
- Keep commits small and focused, with clear messages.
- Keep `main` working: once the Swift package exists, run `swift build` and `swift test` before pushing.

## Context

- Design decisions live in [`docs/DESIGN.md`](docs/DESIGN.md). Read it before changing behavior, and update it when a decision changes.
