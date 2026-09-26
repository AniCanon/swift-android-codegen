# Bridging `AsyncStream` to Kotlin `Flow`

Date: 2026-09-26
Status: Approved; spike complete
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
- `T` must be a non-primitive named type jextract can export (public struct/class, or enum using the
  existing discriminator pattern). Other element shapes are skipped with a warning.
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

## Spike results (2026-09-26)

- **jextract never expands macros.** swift-java 0.6.0 reads each file with `SwiftParser.Parser.parse`
  and has no macro expansion path; it also reads inside `#if` blocks regardless of the condition. A
  macro-emitted class would be invisible to it. **Route: committed Swift sources.**
- **An unguarded stream requirement is safe.** With `observe(projectId:)` un-guarded on
  `ProjectDetailHomeOverviewUseCase`, jextract logs `Failed to import: 'ProjectDetailHomeOverviewUseCase.observe(projectId:)'`
  and skips only that member. Generated Java and Swift thunks were byte-identical to before, the
  Android Swift build succeeded, and no protocol wrapper failed (`enableJavaCallbacks` is `false`).
- **Initializers taking `any P` export.** jextract already exports e.g.
  `DefaultSendShareLookUseCase.init(_T0 extends AssetClient, ...)`, so the factory is a plain
  `public init(_ useCase: any P, ...)` on the generated class.

## Generated Swift

Per protocol `P` with stream methods, one committed file `<P>+AndroidStreams.swift` in the tool-owned
`swiftOutputDir`, guarded by `#if canImport(SwiftJava)` (compiled by the Android and JVM test-support
builds, invisible to iOS/Xcode and the macOS Shared tests). Per stream method `m`:

```swift
public final class <P><M>Observation: Sendable {
    private let observation: StreamObservation<T>

    public init(_ useCase: any P, <m's parameters>) {
        self.observation = StreamObservation(useCase.m(<arguments>))
    }

    public func next() async throws -> T? { try await self.observation.next() }   // throwing stream
    public func next() async -> T? { try? await self.observation.next() }         // plain stream

    public func cancel() async { await self.observation.cancel() }
}
```

`StreamObservation<Element>` is public, hand-written and unit-tested in the `SwiftAndroidCodegen`
library (so Shared's pin moves to 0.4.0). It pumps the source inside its own `Task` into a relay
stream; `cancel()` cancels the pump and finishes the relay, so an in-flight `next()` returns `nil` and
the source's `onTermination` runs. The current hand-written holders only drop the iterator, which
guarantees neither.

## Generator changes

- `SwiftSourceAnalyzer`: recognise non-async methods returning `AsyncStream<T>` or
  `AsyncThrowingStream<T, Error>`; `BridgeDescriptor.Method` gains `kind` (`.async` or
  `.stream(throwing:)`) and `Param` gains its external `label`. The element must be a non-primitive
  named type; `Data`, arrays, optionals and primitives are skipped with a warning like every other
  unsupported shape. An element type jextract cannot export surfaces as a Kotlin compile error on the
  generated bridge naming the type.
- `SwiftStreamEmitter`: emits `<P>+AndroidStreams.swift`.
- `KotlinBridgeEmitter`: for a stream method, emits a cold `fun m(...): Flow<T>` that constructs
  `<P><M>Observation.`init`(wrapped, args..., arena)` and feeds `observationFlow` with `next(arena)`
  and `cancel()`, each inside `withContext(Dispatchers.IO)`. Arena is `DEFAULT_SWIFT_JAVA_AUTO_ARENA`.
- CLI: optional `--swift-output-dir`. When given, its `*+AndroidStreams.swift`
  files are deleted and regenerated each run, so removed streams leave no orphans. One run writes both
  the Swift and the Kotlin; neither depends on jextract output.
- Gradle: optional `swiftOutputDir` on the extension and task. The app orders `swiftBindingsBuild*`
  after `generateSwiftAndroidBridges` inside `generateBridges`.
- Runtime: `observationFlow` moves into `dev.anicanon.swiftandroid.codegen.runtime`, with JVM tests.
- README: a "Streams" section with the author and Android contracts.
- Version 0.4.0, published to GitHub Packages.

## Adoption in anicanon-companion (proof)

- `ProjectListUseCase`, `ProjectDetailHomeOverviewUseCase`, `ProjectDetailGalleryOverviewUseCase`:
  expose only `observe(...)`, un-guarded; delete `makeObservation`, their Observation classes, their state actors
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
  ViewModel tests for project list, home and gallery; an iOS build. Manual emulator run: the three
  screens load and update live. Stream termination on cancel is covered by the `StreamObservation`
  unit tests (`os` is unavailable to Shared on Android, so it is not logged there).

## Risks

- Element type not exportable by jextract → Kotlin compile error on the generated bridge naming it.
- jextract output churn → review the generated diff; do not work from a worktree under `/tmp`.

## Out of scope

- The shared server-wait engine and per-feature progress values (next spec).
- Watch-while-open waits: sequence review, sketch renders.
- A real Android event-stream client.
