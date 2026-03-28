# Migrate Pug iOS app to Swift 6 language mode

## Background

The Xcode project currently uses `SWIFT_VERSION = 5.0`, which means concurrency
violations are warnings (or silently ignored) rather than errors. The TestHarness
uses the Swift 6 compiler in strict mode (via `swift build`), which is how we
discovered a real bug: `QuizContext.build()` was reading `pairCorpus.items` — a
`@MainActor`-isolated property — from a non-isolated async context. Fixed in the
TestHarness by capturing a snapshot via `await MainActor.run { pairCorpus.items }`,
but the same class of issue may exist elsewhere in the app.

## How to audit before committing

In Xcode, set **Strict Concurrency Checking** to `Complete` in build settings
(target or project level) while keeping `SWIFT_VERSION = 5.0`. This turns
violations into warnings rather than errors, so you can see the full scope before
flipping the switch.

## How to migrate

1. Set `SWIFT_VERSION = 6.0` in the Xcode project (all targets).
2. Fix all resulting errors — likely concentrated in `nonisolated` async functions
   that touch `@MainActor` objects.
3. Keep the TestHarness Package.swift at `swift-tools-version: 5.9`; it already
   compiles under Swift 6 strict mode and will stay in sync.

## Why it's probably not too bad

The codebase is already well-structured for Swift 6: session classes are
`@MainActor`, models use `@Observable`, and infrastructure (database, network)
is passed as explicit parameters. The surface area for violations is relatively
small.
