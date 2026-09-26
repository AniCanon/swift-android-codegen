# swift-android-codegen

Generate type-safe Kotlin bridge classes from Swift source code. Built for projects that share business logic between iOS (native Swift) and Android (via [swift-java](https://github.com/swiftlang/swift-java)).

The tool reads your `@AndroidBridge`-annotated Swift types, parses them with [swift-syntax](https://github.com/swiftlang/swift-syntax), and emits idiomatic Kotlin `suspend fun` wrappers — so your Android code calls clean coroutine APIs instead of raw JNI bindings.

## The problem

swift-java generates Java bindings for your Swift types. These bindings work, but they expose low-level concerns: `CompletableFuture` return types, `SwiftArena` memory management, array-to-typed-array conversions. Every call site has to deal with this boilerplate.

**Before** (raw swift-java bindings):
```kotlin
val result = withContext(Dispatchers.IO) {
    useCase.fetch(SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA).whenComplete { value, error -> ... }
}
```

**After** (generated bridge):
```kotlin
val bridge = ProjectListUseCaseBridge(useCase)
val result = bridge.fetch()
```

## How it works

1. You annotate Swift types with `@AndroidBridge("BridgeName")`
2. You run `./gradlew generateSwiftAndroidBridges` to invoke the `bridge-gen` CLI
3. The CLI parses your Swift source with swift-syntax and generates Kotlin files
4. Generated bridges are committed to source control and compiled with normal builds

```
Swift source ──→ swift-syntax AST ──→ BridgeDescriptor ──→ Kotlin source
     (@AndroidBridge)      (analyzer)         (emitter)        (.kt files)
```

## Setup

### 1. Add the Swift macro to your shared package

In your `Package.swift`, add the `SwiftAndroidCodegen` dependency:

```swift
// swift-tools-version: 6.0
let package = Package(
    name: "MySharedCode",
    dependencies: [
        .package(path: "../swift-android-codegen/swift-macro"),
    ],
    targets: [
        .target(
            name: "MySharedCode",
            dependencies: [
                .product(name: "SwiftAndroidCodegen", package: "swift-macro"),
            ]
        ),
    ]
)
```

### 2. Apply the Gradle plugin

Publish to your local Maven repository:

```bash
cd swift-android-codegen
./gradlew publishToMavenLocal
```

Add `mavenLocal()` to your `settings.gradle.kts` plugin repositories:

```kotlin
pluginManagement {
    repositories {
        mavenLocal()
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
```

In your `app/build.gradle.kts`:

```kotlin
plugins {
    id("dev.anicanon.swift-android-codegen") version "0.4.0"
}

// Generated sources are committed — not ephemeral build output
val swiftAndroidBridgesDir = file("src/generated/bridges")

swiftAndroidCodegen {
    bridgeGenDir.set(rootDir.resolve("../swift-android-codegen/swift-macro").normalize())
    swiftSourceDir.set(file("../Shared/Sources/MySharedCode"))
    outputDir.set(swiftAndroidBridgesDir)
    bridgePackage.set("com.example.bridge.generated")
    sourcePackage.set("com.example.shared")
    // Owned by the tool: its +AndroidStreams.swift files are replaced on every run.
    swiftOutputDir.set(file("../Shared/Sources/MySharedCode/Generated/AndroidStreams"))
}

android {
    sourceSets {
        getByName("main").kotlin.srcDir(swiftAndroidBridgesDir)
    }
}
```

### 3. Generate bridges

Run the codegen task after changing Swift `@AndroidBridge` annotations or public API:

```bash
./gradlew generateSwiftAndroidBridges
```

Generated Kotlin files are written to `src/generated/bridges/` and committed to version control. Normal builds compile from the committed sources — no codegen runs during `assembleDebug`.

### 4. Add the runtime dependency

```kotlin
dependencies {
    implementation("dev.anicanon.swiftandroid.codegen:runtime:0.4.0")
}
```

The runtime provides `CompletableFuture<T>.await()` and `observationFlow`, which backs generated stream methods.

## Usage

### Annotate your Swift types

Annotate the protocol your features depend on. Any conforming instance — the production implementation or a test stub — can then be bridged.

```swift
import SwiftAndroidCodegen

@AndroidBridge("ProjectListUseCaseBridge")
public protocol ProjectListUseCase: Sendable {
    func fetch() async throws -> ProjectListOverview
    func followProject(projectId: String) async throws -> ProjectFollowState
}
```

Classes and structs can be annotated too; only their `public` async methods are bridged.

### What gets generated

```kotlin
class ProjectListUseCaseBridge(
    private val projectListUseCase: ProjectListUseCase,
) {
    private val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA

    suspend fun fetch(): ProjectListOverview =
        withContext(Dispatchers.IO) {
            projectListUseCase.fetch(arena)
                .await()
        }

    suspend fun followProject(projectId: String): ProjectFollowState =
        withContext(Dispatchers.IO) {
            projectListUseCase.followProject(projectId, arena)
                .await()
        }
}
```

The bridge wraps the Swift instance it is given. It never constructs Swift objects itself, so creating the instance — and its dependencies — stays with the app.

### Use from Android

```kotlin
val bridge = ProjectListUseCaseBridge(useCase)
val overview = bridge.fetch() // suspend fun, use from any coroutine scope
```

## Streams

Streams are bridged only on `@AndroidBridge` protocols — a class or struct bridge's stream methods are
skipped with a warning; its async methods still bridge normally. A non-async protocol requirement
returning `AsyncStream<T>` or `AsyncThrowingStream<T, Error>` becomes a cold Kotlin `Flow<T>`:

```swift
@AndroidBridge("HomeUseCaseBridge")
public protocol HomeUseCase: Sendable {
    func observe(projectId: String) -> AsyncStream<HomeOverview>
}
```

```kotlin
bridge.observe(projectId).collect { overview -> /* ... */ }
```

generates:

```kotlin
fun observe(projectId: String): Flow<HomeOverview> =
    observationFlow(
        open = { HomeUseCaseObserveObservation.`init`(homeUseCase, projectId, arena) },
        next = { observation ->
            withContext(Dispatchers.IO) {
                observation.next(arena)
                    .await()
                    .orElse(null)
            }
        },
        cancel = { observation ->
            withContext(Dispatchers.IO) {
                observation.cancel()
                    .await()
            }
        },
    )
```

- `bridge-gen` writes `HomeUseCase+AndroidStreams.swift` (a `HomeUseCaseObserveObservation` class) into `swiftOutputDir`. Commit it, and add that directory to jextract's `swiftFilterInclude`. Run `generateSwiftAndroidBridges` before jextract.
- The stream requirement needs no `#if` guard: jextract skips it with a warning and exports the generated class instead.
- `T` must be `Sendable` — the generated `StreamObservation<T>` requires it, matching every other bridged type.
- Collection opens the Swift stream when the `Flow` is collected, not when the bridge method is called; completion, `first()`/`take()` and collector cancellation all close it exactly once, which runs its `onTermination`.
- A throwing stream's error fails the flow. `T` must be a named type jextract exports; `String`, primitives, arrays, optionals and `Data` are skipped with a warning.
- Generated Swift is not wrapped in `#if`: jextract evaluates conditions statically and cannot see guarded code, so the classes compile on every platform that builds the shared package.

## Type mappings

| Swift | Kotlin |
|-------|--------|
| `String` | `String` |
| `Int` | `Long` |
| `Double` | `Double` |
| `Float` | `Float` |
| `Bool` | `Boolean` |
| `Data` | `ByteArray` |
| `[Type]` | `List<Type>` |
| `Type?` | `Type?` |
| `Void` / no return | Unit (omitted) |
| `AsyncStream<T>` / `AsyncThrowingStream<T, Error>` | `Flow<T>` |

`Data` parameters are automatically converted via `Data.fromByteArray()`. Array parameters are converted with `.toTypedArray()` and array returns with `.toList()`.

## What the analyzer captures

The `bridge-gen` CLI scans for types annotated with `@AndroidBridge` and extracts:

- **The annotated type** — becomes the bridge's single constructor parameter.
- **Async methods** — become `suspend fun` on the bridge: every async requirement of a protocol, and the `public` async methods of a class or struct. Synchronous methods are ignored.
- **Return types** — mapped to Kotlin equivalents. Void methods omit the return type.
- **Stream methods** — non-async protocol requirements returning `AsyncStream`/`AsyncThrowingStream` become `Flow`-returning functions. Only bridged on protocols; a class or struct bridge skips them with a warning.

Types without `@AndroidBridge` are ignored. The `@AndroidBridge` macro itself is a no-op peer macro — it produces no code at compile time and exists purely as a marker for the code generator.

## Configuration reference

| Property | Required | Description |
|----------|----------|-------------|
| `bridgeGenDir` | Yes | Path to the Swift package containing `bridge-gen` (the `swift-macro` directory) |
| `swiftSourceDir` | Yes | Directory with `@AndroidBridge`-annotated Swift files |
| `outputDir` | Yes | Where to write generated `.kt` files |
| `bridgePackage` | Yes | Kotlin package for generated bridge classes |
| `sourcePackage` | Yes | Kotlin package where swift-java generates its types |
| `runtimePackage` | No | Package for the `await()` extension (default: `dev.anicanon.swiftandroid.codegen.runtime`) |
| `swiftOutputDir` | No | Directory for generated Swift stream observations; its `+AndroidStreams.swift` files are replaced on every run |

## CLI usage

You can also run the CLI directly without Gradle:

```bash
cd swift-macro
swift run bridge-gen \
    --source-dir /path/to/swift/sources \
    --output-dir /path/to/kotlin/output \
    --bridge-package com.example.bridge.generated \
    --source-package com.example.shared \
    --swift-output-dir /path/to/swift/generated
```

## Project structure

```
swift-android-codegen/
├── swift-macro/                          # Swift Package
│   ├── Package.swift
│   ├── Sources/
│   │   ├── SwiftAndroidCodegen/          # @AndroidBridge macro
│   │   ├── SwiftAndroidCodegenMacros/    # Compiler plugin (no-op peer macro)
│   │   ├── BridgeGenCore/               # Analyzer + emitter library
│   │   └── BridgeGen/                   # CLI entry point
│   └── Tests/
│       ├── SwiftAndroidCodegenTests/     # Macro expansion tests
│       └── BridgeGenTests/              # Analyzer + emitter tests
├── runtime/                             # Kotlin runtime (await extension)
│   └── src/main/kotlin/.../SwiftBridgeExtensions.kt
└── gradle-plugin/                       # Gradle integration
    └── src/main/java/.../
        ├── SwiftAndroidCodegenPlugin.java
        ├── SwiftAndroidCodegenExtension.java
        └── GenerateSwiftAndroidBridgesTask.java
```

## Design decisions

### Bridges hide `SwiftArena`

This is intentional. `SwiftArena` is a swift-java memory lifecycle detail — it shouldn't leak into your Kotlin API. Every bridge registers its Swift instances with swiftkit's process-wide `SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA`, the same arena swift-java's own generated overloads use. Each Swift object is still freed individually once its Kotlin wrapper becomes unreachable; the arena only routes that cleanup. Your code never touches arenas.

Bridges never call `SwiftArena.ofAuto()` themselves: in swift-java every `ofAuto()` call starts a dedicated cleaner thread that is never reclaimed, so an arena per bridge instance leaks one thread per bridge created.

### No auth or factory injection

The bridge takes the Swift instance and nothing else. How that instance and its dependencies are created — auth tokens, API client lifecycle, dependency injection — is your concern. The code generator is deliberately unopinionated about this. Wire it however makes sense for your app.

### Only async methods

The generator only creates bridge methods for functions marked `async` (and, on classes and structs, `public`). Synchronous helpers are excluded. This keeps the generated API surface intentional — only methods designed for cross-platform use get bridged.

## Dependencies

**Swift Package:**
- [swift-syntax](https://github.com/swiftlang/swift-syntax) — AST parsing
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) — CLI

**Kotlin Runtime:**
- [kotlinx-coroutines](https://github.com/Kotlin/kotlinx.coroutines) — `suspendCancellableCoroutine` for the `await()` bridge
- [swiftkit](https://github.com/swiftlang/swift-java) — `SwiftArena` for JNI memory management (compileOnly)

## License

Apache-2.0 — see [LICENSE](LICENSE) for details.
