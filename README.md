# swift-android-codegen

Generate type-safe Kotlin bridge classes from Swift source code. Built for projects that share business logic between iOS (native Swift) and Android (via [swift-java](https://github.com/swiftlang/swift-java)).

The tool reads your `@AndroidBridge`-annotated Swift types, parses them with [swift-syntax](https://github.com/swiftlang/swift-syntax), and emits idiomatic Kotlin `suspend fun` wrappers — so your Android code calls clean coroutine APIs instead of raw JNI bindings.

## The problem

swift-java generates Java bindings for your Swift types. These bindings work, but they expose low-level concerns: `CompletableFuture` return types, `SwiftArena` memory management, array-to-typed-array conversions. Every call site has to deal with this boilerplate.

**Before** (raw swift-java bindings):
```kotlin
val arena = SwiftArena.ofAuto()
val useCase = DefaultProjectListUseCase.init(projectClient, profileClient, arena)
val result = withContext(Dispatchers.IO) {
    useCase.fetch(arena).whenComplete { value, error -> ... }
}
```

**After** (generated bridge):
```kotlin
val bridge = ProjectListBridge(projectClient, profileClient)
val result = bridge.fetch()
```

## How it works

1. You annotate Swift types with `@AndroidBridge("BridgeName")`
2. At build time, the Gradle plugin invokes the `bridge-gen` CLI
3. The CLI parses your Swift source with swift-syntax and generates Kotlin files
4. Generated bridges wrap each public async method as a Kotlin `suspend fun`

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

In your Android project's `settings.gradle.kts`:

```kotlin
pluginManagement {
    val swiftAndroidCodegenDir = settingsDir.resolve("../swift-android-codegen").normalize()
    if (swiftAndroidCodegenDir.exists()) {
        includeBuild(swiftAndroidCodegenDir)
    }
}
```

In your `app/build.gradle.kts`:

```kotlin
plugins {
    id("dev.anicanon.swift-android-codegen")
}

val bridgeOutputDir = layout.buildDirectory.dir("generated/source/swiftAndroidCodegen/main/kotlin")

swiftAndroidCodegen {
    bridgeGenDir.set(rootDir.resolve("../swift-android-codegen/swift-macro").normalize())
    swiftSourceDir.set(file("../Shared/Sources/MySharedCode"))
    outputDir.set(bridgeOutputDir)
    bridgePackage.set("com.example.bridge.generated")
    sourcePackage.set("com.example.shared")
}

android {
    sourceSets {
        getByName("main").kotlin.srcDir(bridgeOutputDir)
    }
}
```

### 3. Add the runtime dependency

```kotlin
dependencies {
    implementation("dev.anicanon.swiftandroid.codegen:runtime:0.1.0-SNAPSHOT")
}
```

The runtime is a single file — a `CompletableFuture<T>.await()` extension that bridges Java futures to Kotlin coroutines with cancellation support.

## Usage

### Annotate your Swift types

```swift
import SwiftAndroidCodegen

@AndroidBridge("ProjectListBridge")
public struct DefaultProjectListUseCase: ProjectListUseCase {
    private let projectClient: any ProjectClient
    private let profileClient: any ProfileClient

    public init(
        projectClient: any ProjectClient,
        profileClient: any ProfileClient
    ) {
        self.projectClient = projectClient
        self.profileClient = profileClient
    }

    public func fetch() async throws -> ProjectListOverview {
        // ...
    }
}
```

### What gets generated

```kotlin
class ProjectListBridge(
    private val projectClient: ProjectClient,
    private val profileClient: ProfileClient,
) {
    private val arena = SwiftArena.ofAuto()
    private val impl = DefaultProjectListUseCase.init(projectClient, profileClient, arena)

    suspend fun fetch(): ProjectListOverview =
        withContext(Dispatchers.IO) {
            impl.fetch(arena).await()
        }
}
```

The bridge mirrors the Swift type's constructor — same parameters, same names. The Swift instance is created once and reused across all method calls. You provide the dependencies; the bridge handles the rest.

### Use from Android

```kotlin
val bridge = ProjectListBridge(projectClient, profileClient)
val overview = bridge.fetch() // suspend fun, use from any coroutine scope
```

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

`Data` parameters are automatically converted via `Data.fromByteArray()`. Array parameters are converted with `.toTypedArray()` and array returns with `.toList()`.

## What the analyzer captures

The `bridge-gen` CLI scans for types annotated with `@AndroidBridge` and extracts:

- **Init parameters** — become the bridge's constructor. `any Protocol` types are recognized as protocol dependencies.
- **Public async methods** — become `suspend fun` on the bridge. Synchronous and non-public methods are ignored.
- **Return types** — mapped to Kotlin equivalents. Void methods omit the return type.

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

## CLI usage

The Gradle plugin invokes this automatically, but you can run it directly:

```bash
cd swift-macro
swift run bridge-gen \
    --source-dir /path/to/swift/sources \
    --output-dir /path/to/kotlin/output \
    --bridge-package com.example.bridge.generated \
    --source-package com.example.shared
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

This is intentional. `SwiftArena` is a swift-java memory lifecycle detail — it shouldn't leak into your Kotlin API. Each bridge creates a single `SwiftArena.ofAuto()` and Swift instance at construction time, reused across all method calls. Cleanup is handled by the JVM garbage collector. Your code never touches arenas.

### No auth or factory injection

The bridge takes the same dependencies as the Swift type. If your Swift `init` takes `projectClient: any ProjectClient`, the generated bridge constructor takes `projectClient: ProjectClient`. Period.

How you create those dependencies — auth tokens, API client lifecycle, dependency injection — is your concern. The code generator is deliberately unopinionated about this. Wire it however makes sense for your app.

### Only public async methods

The generator only creates bridge methods for `public` functions marked `async`. Synchronous helpers, private methods, and non-async functions are excluded. This keeps the generated API surface intentional — only methods designed for cross-platform use get bridged.

## Dependencies

**Swift Package:**
- [swift-syntax](https://github.com/swiftlang/swift-syntax) — AST parsing
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) — CLI

**Kotlin Runtime:**
- [kotlinx-coroutines](https://github.com/Kotlin/kotlinx.coroutines) — `suspendCancellableCoroutine` for the `await()` bridge
- [swiftkit](https://github.com/swiftlang/swift-java) — `SwiftArena` for JNI memory management (compileOnly)

## License

Apache-2.0 — see [LICENSE](LICENSE) for details.
