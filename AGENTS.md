# Agent guidelines

## Workflow

This repo uses trunk-based development.

- Commit straight to `main` and push. No feature branches or pull requests needed.
- Keep commits small and focused, with clear messages.
- Keep `main` working: once the Swift package exists, run `swift build` and `swift test` before pushing.

## Context

- Design decisions live in [`docs/DESIGN.md`](docs/DESIGN.md). Read it before changing behavior, and update it when a decision changes.

## Swift settings

- Swift 6 language mode. Every target in `Package.swift` uses the shared `swiftSettings` array; new targets should too.
- Upcoming features are on (`ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`, `NonisolatedNonsendingByDefault`, and others; see `Package.swift`). In practice:
  - write `any` for existentials
  - an import is internal unless marked `public import`; use `public import` only when the module's types appear in public API
  - import every module a file uses directly
  - plain `async` functions run on the caller's actor; mark one `@concurrent` to run it off the actor
- `WhatFeatureCore` also uses strict memory safety: mark unsafe code with `unsafe`.
