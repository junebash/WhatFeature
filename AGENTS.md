# Agent guidelines

## Workflow

This repo uses trunk-based development.

- Commit straight to `main` and push. No feature branches or pull requests needed.
- Keep commits small and focused, with clear messages.
- Keep `main` working: run `swift build` and `swift test` before pushing. CI (`.github/workflows/ci.yml`) runs `swift test` on Linux and macOS for every push; check it after pushing.

## Context

- Design decisions live in [`docs/DESIGN.md`](docs/DESIGN.md). Read it before changing behavior, and update it when a decision changes.

## Swift settings

- Swift 6 language mode. Every target in `Package.swift` uses the shared `swiftSettings` array; new targets should too.
- Upcoming features are on (`ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`, `NonisolatedNonsendingByDefault`, and others; see `Package.swift`). In practice:
  - write `any` for existentials
  - an import is internal unless marked `public import`; use `public import` only when the module's types appear in public API
  - import every module a file uses directly
  - plain `async` functions run on the caller's actor; mark one `@concurrent` to run it off the actor
- Never block a thread in async code: no semaphores, `Thread.sleep`, `waitUntilExit`, or synchronous waits on I/O. Blocking Swift concurrency's shared threads can stall everything else in the process (it froze the macOS test run for 60 seconds once). Use async APIs: GRDB's async `read`/`write`, `Task.sleep`, and [swift-subprocess](https://github.com/swiftlang/swift-subprocess) to run programs, never Foundation's `Process`. `Mutex` is fine for short, synchronous critical sections.
- `WhatFeatureCore` also uses strict memory safety: mark unsafe code with `unsafe`.
- Name clashes to know about: Foundation's `Predicate` (so ours is `Condition.Predicate`), Hummingbird's `Environment` (write `WhatFeatureStorage.Environment` where both are imported), and ArgumentParser's `@Flag` (the CLI module aliases `Flag` to ArgumentParser's; write the model as `WhatFeatureCore.Flag`).

## CLI

- Admin commands go through `AdminClient` and the admin API, never the database file. Only `db token …` touches the file, for bootstrapping.
