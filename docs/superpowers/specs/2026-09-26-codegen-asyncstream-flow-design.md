# Bridging `AsyncStream` to Kotlin `Flow`

Date: 2026-09-26
Status: Draft, awaiting review
Target release: 0.4.0

## Goal

A Shared author declares a stream once, as a Swift `AsyncStream` or `AsyncThrowingStream`, on an
`@AndroidBridge` protocol. iOS consumes it directly; Android receives a generated Kotlin `Flow`. No
hand-written Observation classes, no `makeObservation` requirements, no `#if !os(Android)` guards.

This is the foundation for moving every "wait for server work" decision in the AniCanon companion
into Shared (outfit, face sheet, backdrop, Quick Create, sequence review, sketch renders). Those
migrations are separate specs and are out of scope here.

## Background

- `bridge-gen` runs **after** jextract (`generateBridges` depends on `swiftBindingsBuildDebug`). It
  can only wrap what jextract already exported, and jextract cannot export `AsyncStream`.
- The companion app works around this by hand in three places (`ProjectListUseCase`,
  `ProjectDetailHomeOverviewUseCase`, `ProjectDetailGalleryOverviewUseCase`): an `observe()` stream
  hidden from Android, a `makeObservation()` requirement, a public Observation class with
  `next()`/`cancel()`, a private actor per class holding the iterator, and a Kotlin extension that
  feeds `observationFlow` in the app.
- Swift→Java callbacks are not an option: they are unusable for async protocols in this setup.
  Everything here is pull-based.

## Author contract

```swift
@AndroidBridge("OutfitGenerationProgressUseCaseBridge")
public protocol OutfitGenerationProgressUseCase: Sendable {
    func observe(projectId: String, sessionId: String) -> AsyncStream<OutfitGenerationProgress>
}
```

- A bridged stream method is a non-`async` method returning `AsyncStream<T>` or
  `AsyncThrowingStream<T, Error>`.
- `T` must already be exportable by jextract (public struct/class, or enum using the existing
  discriminator pattern). If it is not, generation fails with an error naming `T`.
- iOS calls `observe(...)` directly. Nothing is generated for iOS.

## Android contract

```kotlin
class OutfitGenerationProgressUseCaseBridge(...) {
    fun observe(projectId: String, sessionId: String): Flow<OutfitGenerationProgress>
}
```

- Cold `Flow`. Collection starts the Swift stream.
- The flow completes when the Swift stream finishes.
- `AsyncThrowingStream`: the flow fails with the Swift error, unwrapped the same way `await()` does.
- Collector cancellation, early termination (`first`, `take`) and normal completion all call the
  Swift `cancel()` exactly once.

## Generated Swift

Per stream method `m` on protocol `P`, guarded by `#if os(Android)`:

- `public final class <P><M>Observation` (e.g. `ProjectListUseCaseObserveObservation`) exposing `next() async [throws] -> T?` and
  `cancel() async`.
- A public factory taking the use case and the method's arguments, returning the Observation. Generated
  code cannot add requirements to the author's protocol, so the factory is free-standing or on the
  Observation type; the spike settles which form jextract exports.
- One generic internal state holder backs every generated class. It consumes the stream inside its own
  `Task`; `cancel()` cancels that task, so an in-flight `next()` returns and the stream's
  `onTermination` runs. The current hand-written holders only drop the iterator, which guarantees
  neither.

### Emission route (decided by spike)

- **(a) Macro.** `@AndroidBridge` becomes a peer/extension macro that emits the Observation and
  factory. Valid only if jextract exports macro-expanded public declarations.
- **(b) Committed sources.** A new `generateSwiftAndroidBridgeSources` task writes
  `<swiftSourceDir>/Generated/*Observation.swift` and runs **before** `swiftBindingsBuild*`. Files are
  committed, like the generated Kotlin.

Spike: add a throwaway public macro-emitted class to Shared, run jextract, check for its
`+SwiftJava.swift` output and Java class. Present → (a); absent → (b). The spike code is discarded;
the result is recorded in this spec before implementation starts.

## Generator changes

- `SwiftSourceAnalyzer`: recognise stream methods; add `BridgeDescriptor` method kind
  `stream(element:, throwing:)`. Unsupported shapes keep today's warn-and-skip behaviour.
- New Swift emitter for the Observation, factory and shared state holder (route a or b).
- `KotlinBridgeEmitter`: for a stream method, emit a `fun` returning
  `Flow<T> = flow { emitAll(observationFlow(obs::next, obs::cancel)) }`, creating the Observation via the
  factory with `DEFAULT_SWIFT_JAVA_AUTO_ARENA` (never `ofAuto`).
- Runtime: move `observationFlow` into `dev.anicanon.swiftandroid.codegen.runtime`.
- README: a "Streams" section with the author and Android contracts.
- Version 0.4.0, published to GitHub Packages.

## Adoption in anicanon-companion (proof)

- `ProjectListUseCase`, `ProjectDetailHomeOverviewUseCase`, `ProjectDetailGalleryOverviewUseCase`:
  expose only `observe(...)`; delete `makeObservation`, their Observation classes, their state actors
  and the `#if !os(Android)` guards.
- Android: delete `core/runtime/ObservationFlow.kt` and the three `*Overviews.kt` extensions; callers
  use the generated `Flow`.
- Delete orphaned generated bridge files by hand; run `generateBridges` and `assembleDebug` as separate
  steps.
- iOS behaviour is unchanged.

## Testing

- Codegen: analyzer tests for stream detection (plain and throwing) and for skipped shapes; snapshot
  tests of emitted Swift and Kotlin for a protocol mixing a `suspend` and a stream method.
- Runtime: `observationFlow` calls `cancel()` exactly once on completion, collector cancellation,
  early termination and error.
- App, once per platform when that platform is done: Shared tests for the three use cases; Android
  ViewModel tests for project list, home and gallery. Manual emulator run: the three screens load and
  update, and leaving a screen logs the stream's `onTermination` via `os.Logger`.

## Risks

- jextract ignores macro output → route (b).
- Element type not exportable → generation error naming the type.
- jextract output churn → review the generated diff; do not work from a worktree under `/tmp`.

## Out of scope

- The shared server-wait engine and per-feature progress values (next spec).
- Watch-while-open waits: sequence review, sketch renders.
- A real Android event-stream client.
