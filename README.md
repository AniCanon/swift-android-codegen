# swift-android-codegen

Generates Kotlin bridge classes from Swift source, for apps that share Swift business logic
between iOS and Android through [swift-java](https://github.com/swiftlang/swift-java).

Mark a Swift type with `@AndroidBridge`, run one Gradle task, and your Android code gets
coroutine-friendly Kotlin: `suspend fun` for async methods and `Flow` for `AsyncStream`s.

## Why

swift-java's generated Java bindings work, but every call site has to deal with its low-level
details: `CompletableFuture` returns, `SwiftArena` memory management, and array conversions.

Without a bridge:

```kotlin
val result = withContext(Dispatchers.IO) {
    useCase.fetch(SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA).whenComplete { value, error -> ... }
}
```

With a generated bridge:

```kotlin
val bridge = ProjectListUseCaseBridge(useCase)
val result = bridge.fetch()
```

## How it works

1. Annotate Swift types with `@AndroidBridge("BridgeName")`.
2. Run `./gradlew generateSwiftAndroidBridges`, which calls the `bridge-gen` CLI.
3. `bridge-gen` parses your Swift sources with [swift-syntax](https://github.com/swiftlang/swift-syntax)
   and writes Kotlin bridges (plus Swift helpers for streams).
4. Commit the generated files. Normal builds compile them like any other source.

```
Swift source ──→ swift-syntax AST ──→ BridgeDescriptor ──→ Kotlin source
(@AndroidBridge)     (analyzer)                             (emitter)
```

## Installation

The current release is **0.4.0**. It ships three pieces:

| Piece | Where it comes from |
|-------|---------------------|
| `SwiftAndroidCodegen` Swift library (`@AndroidBridge` macro, `StreamObservation`) | Swift Package Manager, from this repository |
| Gradle plugin `dev.anicanon.swift-android-codegen` | GitHub Packages |
| Kotlin runtime `dev.anicanon.swiftandroid.codegen:runtime` | GitHub Packages |

You also need a local checkout of this repository, because the Gradle task runs `bridge-gen`
from source with `swift run`.

### 1. Swift package

Add the package to the `Package.swift` of your shared Swift code:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyShared",
    dependencies: [
        .package(url: "https://github.com/AniCanon/swift-android-codegen.git", exact: "0.4.0"),
    ],
    targets: [
        .target(
            name: "MyShared",
            dependencies: [
                .product(name: "SwiftAndroidCodegen", package: "swift-android-codegen"),
            ]
        ),
    ]
)
```

To develop against a local checkout instead, use `.package(path: "../swift-android-codegen")`.

### 2. GitHub Packages credentials

GitHub Packages requires authentication for Maven downloads, even for public packages. Create a
personal access token with the `read:packages` scope and add it to `~/.gradle/gradle.properties`:

```properties
gpr.user=your-github-username
gpr.key=ghp_yourtoken
```

### 3. Gradle repositories

In your Android project's `settings.gradle.kts`, add the GitHub Packages repository for both
plugins and dependencies:

```kotlin
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        maven {
            url = uri("https://maven.pkg.github.com/AniCanon/swift-android-codegen")
            credentials {
                username = providers.gradleProperty("gpr.user").get()
                password = providers.gradleProperty("gpr.key").get()
            }
        }
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://maven.pkg.github.com/AniCanon/swift-android-codegen")
            credentials {
                username = providers.gradleProperty("gpr.user").get()
                password = providers.gradleProperty("gpr.key").get()
            }
        }
    }
}
```

### 4. Plugin and runtime

In `app/build.gradle.kts`:

```kotlin
plugins {
    id("dev.anicanon.swift-android-codegen") version "0.4.0"
}

// Generated bridges are committed to source control, not build output.
val swiftAndroidBridgesDir = file("src/generated/bridges")

swiftAndroidCodegen {
    bridgeGenDir.set(rootDir.resolve("../swift-android-codegen/swift-macro").normalize())
    swiftSourceDir.set(file("../Shared/Sources/MyShared"))
    outputDir.set(swiftAndroidBridgesDir)
    bridgePackage.set("com.example.bridge.generated")
    sourcePackage.set("com.example.shared")
    // Only needed if you bridge streams. The tool replaces this directory's
    // +AndroidStreams.swift files on every run.
    swiftOutputDir.set(file("../Shared/Sources/MyShared/Generated/AndroidStreams"))
}

android {
    sourceSets {
        getByName("main").kotlin.srcDir(swiftAndroidBridgesDir)
    }
}

dependencies {
    implementation("dev.anicanon.swiftandroid.codegen:runtime:0.4.0")
}
```

The runtime provides `CompletableFuture<T>.await()` for async methods and `observationFlow` for
streams. It compiles against swiftkit but does not bring it in, so your app must also depend on
the `swiftkit-core` version that matches your swift-java release.

### Working from a local checkout

If you work on this repository alongside your app, include it as a composite build instead of
using the published artifacts. In `settings.gradle.kts`:

```kotlin
pluginManagement {
    includeBuild("../swift-android-codegen") // the Gradle plugin
}

includeBuild("../swift-android-codegen") // the runtime dependency
```

Gradle then builds the plugin and runtime from source, so you can drop the GitHub Packages
repository for them.

## Generating bridges

Run the task after you add or change `@AndroidBridge` types or their public API:

```bash
./gradlew generateSwiftAndroidBridges
```

Kotlin files go to `outputDir` and are committed. Regular builds such as `assembleDebug` compile
the committed files and never run the generator.

## Usage

### Annotate a Swift type

Annotate the protocol your features depend on. Any conforming instance, whether the production
implementation or a test stub, can then be bridged.

```swift
import SwiftAndroidCodegen

@AndroidBridge("ProjectListUseCaseBridge")
public protocol ProjectListUseCase: Sendable {
    func fetch() async throws -> ProjectListOverview
    func followProject(projectId: String) async throws -> ProjectFollowState
}
```

Classes and structs can be annotated too. For those, only `public` async methods are bridged.

### Generated Kotlin

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

The bridge wraps the Swift instance you pass in. It never creates Swift objects itself, so your
app stays in charge of building that instance and its dependencies.

### Calling it from Android

```kotlin
val bridge = ProjectListUseCaseBridge(useCase)
val overview = bridge.fetch() // suspend fun, callable from any coroutine
```

## Streams

A non-async protocol requirement that returns `AsyncStream<T>` or `AsyncThrowingStream<T, Error>`
becomes a cold Kotlin `Flow<T>`:

```swift
@AndroidBridge("HomeUseCaseBridge")
public protocol HomeUseCase: Sendable {
    func observe(projectId: String) -> AsyncStream<HomeOverview>
}
```

```kotlin
bridge.observe(projectId).collect { overview -> /* ... */ }
```

The generated bridge method:

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

### Setup for streams

- Set `swiftOutputDir`. `bridge-gen` writes a Swift file per protocol there, for example
  `HomeUseCase+AndroidStreams.swift` containing a `HomeUseCaseObserveObservation` class.
- Commit those files and add the directory to jextract's `swiftFilterInclude`.
- Run `generateSwiftAndroidBridges` before jextract, so jextract sees the generated classes.

### Rules and behavior

- Streams are bridged only on protocols. On a class or struct bridge, stream methods are skipped
  with a warning; its async methods are still bridged.
- `T` must be `Sendable` and a named type that jextract exports. `String`, primitives, arrays,
  optionals, and `Data` are skipped with a warning.
- The Swift stream opens when the `Flow` is collected, not when the bridge method is called.
- The stream closes exactly once when it completes, when you stop early with `first()` or
  `take()`, or when the collector is cancelled. Closing runs the stream's `onTermination`.
- An error from an `AsyncThrowingStream` fails the flow.
- Don't wrap the stream requirement in `#if`. jextract skips it with a warning and exports the
  generated class instead.
- Generated Swift is also left unguarded. jextract evaluates `#if` statically and cannot see
  guarded code, so the generated classes compile on every platform that builds the package.

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
| `Void` / no return | `Unit` (omitted) |
| `AsyncStream<T>` / `AsyncThrowingStream<T, Error>` | `Flow<T>` |

The bridge converts values for you: `Data` arguments through `Data.fromByteArray()`, array
arguments with `.toTypedArray()`, and array results with `.toList()`.

## What gets bridged

`bridge-gen` looks only at types annotated with `@AndroidBridge`:

- **The annotated type** becomes the bridge's only constructor parameter.
- **Async methods** become `suspend fun`: every async requirement of a protocol, and the `public`
  async methods of a class or struct. Synchronous methods are skipped.
- **Stream methods** on protocols become `Flow`-returning functions (see [Streams](#streams)).
- **Return types** map to Kotlin as listed above.

`@AndroidBridge` is a no-op peer macro. It produces no code at compile time and only marks types
for the generator.

## Configuration reference

| Property | Required | Description |
|----------|----------|-------------|
| `bridgeGenDir` | Yes | Local Swift package that contains `bridge-gen`: this repository's root or its `swift-macro` directory |
| `swiftSourceDir` | Yes | Directory with your `@AndroidBridge`-annotated Swift files |
| `outputDir` | Yes | Where generated `.kt` files are written |
| `bridgePackage` | Yes | Kotlin package for the generated bridges |
| `sourcePackage` | Yes | Kotlin package where swift-java generates your types |
| `runtimePackage` | No | Package of the runtime helpers (default: `dev.anicanon.swiftandroid.codegen.runtime`) |
| `swiftOutputDir` | No | Where generated Swift stream observations are written; its `+AndroidStreams.swift` files are replaced on every run |

## Running the CLI directly

You can run `bridge-gen` without Gradle:

```bash
cd swift-macro
swift run bridge-gen \
    --source-dir /path/to/swift/sources \
    --output-dir /path/to/kotlin/output \
    --bridge-package com.example.bridge.generated \
    --source-package com.example.shared \
    --swift-output-dir /path/to/swift/generated
```

## Design choices

### Bridges hide `SwiftArena`

`SwiftArena` is a swift-java memory detail and shouldn't leak into your Kotlin API. Every bridge
uses swiftkit's shared `SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA`, the same arena
swift-java's own generated overloads use. Each Swift object is still freed on its own once its
Kotlin wrapper is unreachable; the arena only handles the cleanup.

Bridges never call `SwiftArena.ofAuto()`. In swift-java each `ofAuto()` call starts a cleaner
thread that is never reclaimed, so one arena per bridge would leak a thread per bridge.

### No factories or auth

A bridge takes the Swift instance and nothing else. Auth, API client lifecycle, and dependency
injection stay in your app, wired however suits it.

### Only async methods

Only `async` methods (and on classes and structs, only `public` ones) are bridged, plus streams on
protocols. Synchronous helpers stay out, which keeps the Kotlin API limited to what was designed
for cross-platform use.

## Project structure

```
swift-android-codegen/
├── Package.swift                         # Root manifest for SwiftPM consumers
├── swift-macro/                          # Swift sources and tests
│   ├── Sources/
│   │   ├── SwiftAndroidCodegen/          # @AndroidBridge macro, StreamObservation
│   │   ├── SwiftAndroidCodegenMacros/    # Compiler plugin (no-op peer macro)
│   │   ├── BridgeGenCore/                # Analyzer and Kotlin/Swift emitters
│   │   └── BridgeGen/                    # bridge-gen CLI
│   └── Tests/
├── runtime/                              # Kotlin runtime: await(), observationFlow
└── gradle-plugin/                        # generateSwiftAndroidBridges task
```

## Releasing

Pushing a `v*` tag runs the `Publish Packages` workflow, which publishes the Gradle plugin, its
marker, and the runtime to GitHub Packages. The version comes from `version` in
`build.gradle.kts`. The Swift package is consumed straight from the tag.

## Dependencies

**Swift:**
- [swift-syntax](https://github.com/swiftlang/swift-syntax) for parsing
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) for the CLI

**Kotlin runtime:**
- [kotlinx-coroutines](https://github.com/Kotlin/kotlinx.coroutines) for `await()` and `Flow`
- [swiftkit](https://github.com/swiftlang/swift-java) for `SwiftArena` (compile-only)

## License

Apache-2.0. See [LICENSE](LICENSE).
