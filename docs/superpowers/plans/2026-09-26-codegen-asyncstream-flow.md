# AsyncStream → Kotlin Flow Bridging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Shared author declares a stream once as `AsyncStream`/`AsyncThrowingStream` on an `@AndroidBridge` protocol; `bridge-gen` emits a committed Swift Observation class plus a cold Kotlin `Flow` on the bridge, and the companion app's three hand-written Observations are replaced by it.

**Architecture:** A hand-written, tested `StreamObservation<Element>` in the `SwiftAndroidCodegen` library does the pumping and cancellation. `bridge-gen` gains stream-method analysis, a `SwiftStreamEmitter` that writes `<P>+AndroidStreams.swift` (a thin per-method class with `init(_ useCase: any P, …)`, `next()`, `cancel()`) into a tool-owned directory, and a Kotlin emitter branch producing `fun m(…): Flow<T>` over `observationFlow`, which moves into the runtime. One `bridge-gen` run writes both; the app orders jextract after it.

**Tech Stack:** Swift 6 (swift-syntax 603, swift-argument-parser, Swift Testing), Kotlin 2.1 + kotlinx-coroutines 1.10, Gradle (Java plugin), swift-java 0.6.0 jextract (JNI mode), TCA iOS app, MVI Android app.

**Spec:** `docs/superpowers/specs/2026-09-26-codegen-asyncstream-flow-design.md` (this repo). Read it first; the "Spike results" section explains why the Swift side is committed source and why un-guarded stream requirements are safe.

## Global Constraints

- Two repos. Codegen: `~/Projects/swift-android-codegen`, branch `feature/asyncstream-flow-bridges` (already exists, holds the spec). App: `~/Projects/anicanon-companion`, new branch `feature/generated-stream-observations` from `main`.
- Conventional Commits (`feat`, `fix`, `test`, `docs`, `build`, `refactor`, `chore`), present tense, no trailing period.
- **Subagents never commit.** The controller reads the staged diff (`git diff --cached`) and commits.
- Source comments state constraints only: no narrative, no references to specs, plans, tasks, reviews or spikes. Put this line in every subagent brief.
- Swift logging uses `os.Logger`, never `NSLog`/`print` (the CLI's existing `print` warnings are the tool's output channel and stay).
- Hand-written Swift and Kotlin files stay under 600 lines.
- Arena for generated Kotlin: `SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA`, never `ofAuto`.
- Generated Swift is guarded by `#if canImport(SwiftJava)`.
- Codegen version becomes `0.4.0`.
- App repo test runs happen once per platform, after that platform's code is done (Task 8). Build verification is allowed anytime. Never run two `xcodebuild`s at once; `xcodebuild` needs `-skipMacroValidation`.
- Until 0.4.0 is released, every Android/Shared command in the app repo runs with `export SWIFT_ANDROID_CODEGEN_PATH=$HOME/Projects/swift-android-codegen` so Shared resolves the local codegen package. Android Gradle already uses the sibling checkout via `includeBuild`.
- Never work from a worktree under `/tmp` (jextract emits empty thunks there).
- Pushing, opening PRs, tagging and publishing are outward-facing: ask the user before each.

---

### Task 1: `StreamObservation` in the `SwiftAndroidCodegen` library

**Files:**
- Create: `swift-macro/Sources/SwiftAndroidCodegen/StreamObservation.swift`
- Create: `swift-macro/Tests/StreamObservationTests/StreamObservationTests.swift`
- Modify: `swift-macro/Package.swift` (add test target)
- Modify: `Package.swift` (root; add the same test target with `path:`)

**Interfaces:**
- Produces: `public final class StreamObservation<Element: Sendable>: Sendable` with `public init<Source: AsyncSequence & Sendable>(_ source: Source) where Source.Element == Element`, `public func next() async throws -> Element?`, `public func cancel() async`.

- [ ] **Step 1: Add the test target to both manifests**

In `swift-macro/Package.swift`, append to `targets`:

```swift
        .testTarget(
            name: "StreamObservationTests",
            dependencies: ["SwiftAndroidCodegen"]
        ),
```

In the root `Package.swift`, append to `targets`:

```swift
        .testTarget(
            name: "StreamObservationTests",
            dependencies: ["SwiftAndroidCodegen"],
            path: "swift-macro/Tests/StreamObservationTests"
        ),
```

- [ ] **Step 2: Write the failing tests**

`swift-macro/Tests/StreamObservationTests/StreamObservationTests.swift`:

```swift
import SwiftAndroidCodegen
import Testing

@Suite("StreamObservation")
struct StreamObservationTests {
    struct Boom: Error, Equatable {}

    @Test("Delivers every element, then nil")
    func deliversElementsThenNil() async throws {
        let observation = StreamObservation(AsyncStream<Int> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.finish()
        })

        #expect(try await observation.next() == 1)
        #expect(try await observation.next() == 2)
        #expect(try await observation.next() == nil)
        #expect(try await observation.next() == nil)
    }

    @Test("Rethrows the source error once, then returns nil")
    func rethrowsSourceError() async throws {
        let observation = StreamObservation(AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(1)
            continuation.finish(throwing: Boom())
        })

        #expect(try await observation.next() == 1)
        await #expect(throws: Boom.self) { try await observation.next() }
        #expect(try await observation.next() == nil)
    }

    @Test("Cancel ends a waiting next with nil")
    func cancelEndsWaitingNext() async throws {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let observation = StreamObservation(stream)

        async let pending = observation.next()
        await observation.cancel()

        #expect(try await pending == nil)
        withExtendedLifetime(continuation) {}
    }

    @Test("Cancel terminates the source")
    func cancelTerminatesSource() async {
        let (terminated, terminatedContinuation) = AsyncStream<Void>.makeStream()
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        continuation.onTermination = { _ in
            terminatedContinuation.yield()
            terminatedContinuation.finish()
        }
        let observation = StreamObservation(stream)

        await observation.cancel()

        var iterator = terminated.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test("Next after cancel returns nil even when the source keeps yielding")
    func nextAfterCancelReturnsNil() async throws {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let observation = StreamObservation(stream)

        await observation.cancel()
        continuation.yield(7)

        #expect(try await observation.next() == nil)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ~/Projects/swift-android-codegen/swift-macro && swift test --filter StreamObservationTests`
Expected: build failure, `cannot find 'StreamObservation' in scope`.

- [ ] **Step 4: Implement `StreamObservation`**

`swift-macro/Sources/SwiftAndroidCodegen/StreamObservation.swift`:

```swift
/// Pull-based access to an `AsyncSequence` for callers that cannot receive callbacks.
///
/// Serves a single consumer: overlapping `next()` calls are not supported.
public final class StreamObservation<Element: Sendable>: Sendable {
    private let relay: StreamObservationRelay<Element>
    private let pump: Task<Void, Never>

    public init<Source: AsyncSequence & Sendable>(_ source: Source) where Source.Element == Element {
        let relay = StreamObservationRelay<Element>()
        self.relay = relay
        self.pump = Task {
            do {
                for try await element in source {
                    await relay.push(element)
                }
                await relay.finish(.success(()))
            } catch {
                await relay.finish(.failure(error))
            }
        }
    }

    deinit {
        self.pump.cancel()
        let relay = self.relay
        Task { await relay.cancel() }
    }

    /// `nil` once the source has finished or the observation was cancelled.
    public func next() async throws -> Element? {
        try await self.relay.next()
    }

    /// Stops the source, drops undelivered elements and ends any waiting `next()` with `nil`.
    public func cancel() async {
        self.pump.cancel()
        await self.relay.cancel()
    }
}

private actor StreamObservationRelay<Element: Sendable> {
    private var buffer: [Element] = []
    /// `nil` while open. A failure is delivered once, then the relay reads as finished.
    private var ending: Result<Void, Error>?
    private var waiter: CheckedContinuation<Element?, Error>?

    func push(_ element: Element) {
        guard self.ending == nil else { return }
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: element)
        } else {
            self.buffer.append(element)
        }
    }

    func finish(_ result: Result<Void, Error>) {
        guard self.ending == nil else { return }
        self.ending = result
        guard let waiter = self.waiter else { return }
        self.waiter = nil
        self.ending = .success(())
        switch result {
        case .success:
            waiter.resume(returning: nil)
        case let .failure(error):
            waiter.resume(throwing: error)
        }
    }

    func cancel() {
        self.buffer.removeAll()
        self.finish(.success(()))
    }

    func next() async throws -> Element? {
        if !self.buffer.isEmpty {
            return self.buffer.removeFirst()
        }
        if let ending = self.ending {
            self.ending = .success(())
            if case let .failure(error) = ending {
                throw error
            }
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.waiter = continuation
        }
    }
}
```

A source that finishes normally still delivers its buffered elements before `nil`; `cancel()` discards them.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ~/Projects/swift-android-codegen/swift-macro && swift test --filter StreamObservationTests`
Expected: 5 tests pass, no concurrency warnings in the build output.

Run: `cd ~/Projects/swift-android-codegen && swift build`
Expected: root manifest builds.

- [ ] **Step 6: Commit (controller)**

```bash
cd ~/Projects/swift-android-codegen
git add Package.swift swift-macro/Package.swift swift-macro/Sources/SwiftAndroidCodegen/StreamObservation.swift swift-macro/Tests/StreamObservationTests
git diff --cached
git commit -m "feat: add StreamObservation for pull-based stream access"
```

---

### Task 2: Analyzer and descriptor support for stream methods

**Files:**
- Modify: `swift-macro/Sources/BridgeGenCore/BridgeDescriptor.swift`
- Modify: `swift-macro/Sources/BridgeGenCore/SwiftSourceAnalyzer.swift`
- Test: `swift-macro/Tests/BridgeGenTests/SwiftSourceAnalyzerStreamTests.swift` (new file, keeps the existing test file under the line limit)

**Interfaces:**
- Produces:
  - `BridgeDescriptor.Method.Kind: Sendable, Equatable` with `case async` and `case stream(throwing: Bool)`; `Method.kind: Kind`; `Method.init(name:params:returnType:kind: Kind = .async)`. For a stream method `returnType.swiftType` is the **element** type and `returnType.isVoid == false`.
  - `BridgeDescriptor.Param.label: String?` — the external argument label, `nil` for `_`; `Param.init(name:swiftType:label: String? = nil)`.
  - `SwiftType.swiftSpelling: String`.
  - `BridgeDescriptor.observationTypeName(for: Method) -> String` = `swiftTypeName + Name + "Observation"` (method name with first letter uppercased).
  - `BridgeDescriptor.hasStreamMethods: Bool`.

- [ ] **Step 1: Write the failing tests**

`swift-macro/Tests/BridgeGenTests/SwiftSourceAnalyzerStreamTests.swift`:

```swift
import Testing
@testable import BridgeGenCore

@Suite("SwiftSourceAnalyzer streams")
struct SwiftSourceAnalyzerStreamTests {
    let analyzer = SwiftSourceAnalyzer()

    @Test("Detects an AsyncStream requirement")
    func plainStream() throws {
        let bridges = analyzer.analyzeSource("""
        @AndroidBridge("HomeBridge")
        public protocol HomeUseCase: Sendable {
            func fetch(projectId: String) async -> HomeOverview
            func observe(projectId: String) -> AsyncStream<HomeOverview>
        }
        """)

        let bridge = try #require(bridges.first)
        #expect(bridge.methods.map(\.name) == ["fetch", "observe"])
        let observe = bridge.methods[1]
        #expect(observe.kind == .stream(throwing: false))
        #expect(observe.returnType.swiftType.swiftSpelling == "HomeOverview")
        #expect(observe.returnType.isVoid == false)
        #expect(observe.params.map(\.name) == ["projectId"])
        #expect(observe.params.map(\.label) == ["projectId"])
        #expect(bridge.hasStreamMethods)
        #expect(bridge.observationTypeName(for: observe) == "HomeUseCaseObserveObservation")
        #expect(bridge.methods[0].kind == .async)
    }

    @Test("Detects an AsyncThrowingStream requirement")
    func throwingStream() throws {
        let bridges = analyzer.analyzeSource("""
        @AndroidBridge("ListBridge")
        public protocol ListUseCase: Sendable {
            func observe() -> AsyncThrowingStream<ListOverview, Error>
        }
        """)

        let method = try #require(bridges.first?.methods.first)
        #expect(method.kind == .stream(throwing: true))
        #expect(method.returnType.swiftType.swiftSpelling == "ListOverview")
    }

    @Test("Accepts any Error as the throwing stream failure")
    func anyErrorFailure() throws {
        let bridges = analyzer.analyzeSource("""
        @AndroidBridge("ListBridge")
        public protocol ListUseCase: Sendable {
            func observe() -> AsyncThrowingStream<ListOverview, any Error>
        }
        """)

        #expect(bridges.first?.methods.first?.kind == .stream(throwing: true))
    }

    @Test("Records external labels, nil for underscore")
    func labels() throws {
        let bridges = analyzer.analyzeSource("""
        @AndroidBridge("SceneBridge")
        public protocol SceneUseCase: Sendable {
            func observe(for projectId: String, _ sceneId: String) -> AsyncStream<Scene>
        }
        """)

        let method = try #require(bridges.first?.methods.first)
        #expect(method.params.map(\.name) == ["projectId", "sceneId"])
        #expect(method.params.map(\.label) == ["for", nil])
    }

    @Test("Skips streams whose element cannot be bridged")
    func unsupportedElements() {
        let bridges = analyzer.analyzeSource("""
        @AndroidBridge("BadBridge")
        public protocol BadUseCase: Sendable {
            func names() -> AsyncStream<String>
            func items() -> AsyncStream<[Item]>
            func maybe() -> AsyncStream<Item?>
            func bytes() -> AsyncStream<Data>
        }
        """)

        #expect(bridges.isEmpty)
    }

    @Test("Skips throwing factories, non-Error failures and plain synchronous methods")
    func unsupportedShapes() {
        let bridges = analyzer.analyzeSource("""
        @AndroidBridge("BadBridge")
        public protocol BadUseCase: Sendable {
            func observe() throws -> AsyncStream<Item>
            func typed() -> AsyncThrowingStream<Item, MyError>
            func current() -> Item
        }
        """)

        #expect(bridges.isEmpty)
    }

    @Test("Swift spelling round-trips the parsed shapes")
    func swiftSpelling() {
        #expect(SwiftType.simple("Item").swiftSpelling == "Item")
        #expect(SwiftType.member(base: "Outer", name: "Inner").swiftSpelling == "Outer.Inner")
        #expect(SwiftType.optional(.simple("Item")).swiftSpelling == "Item?")
        #expect(SwiftType.array(.simple("Item")).swiftSpelling == "[Item]")
        #expect(SwiftType.data.swiftSpelling == "Data")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/Projects/swift-android-codegen/swift-macro && swift test --filter "SwiftSourceAnalyzer streams"`
Expected: build failure (`kind`, `label`, `swiftSpelling`, `observationTypeName`, `hasStreamMethods` missing).

- [ ] **Step 3: Extend the descriptor**

In `BridgeDescriptor.swift`, replace the `Method` and `Param` structs and add the helpers:

```swift
    public struct Method: Sendable {
        public enum Kind: Sendable, Equatable {
            case async
            /// `returnType` holds the stream's element type.
            case stream(throwing: Bool)
        }

        public let name: String
        public let params: [Param]
        public let returnType: ReturnType
        public let kind: Kind

        public init(name: String, params: [Param], returnType: ReturnType, kind: Kind = .async) {
            self.name = name
            self.params = params
            self.returnType = returnType
            self.kind = kind
        }
    }

    public struct Param: Sendable {
        public let name: String
        public let swiftType: SwiftType
        /// External argument label; `nil` when the parameter is declared with `_`.
        public let label: String?

        public init(name: String, swiftType: SwiftType, label: String? = nil) {
            self.name = name
            self.swiftType = swiftType
            self.label = label
        }
    }
```

Add to `BridgeDescriptor` (after `wrappedName`):

```swift
    public var hasStreamMethods: Bool {
        methods.contains { if case .stream = $0.kind { true } else { false } }
    }

    /// Name of the generated Swift class that serves `method` to Kotlin.
    public func observationTypeName(for method: Method) -> String {
        swiftTypeName + method.name.prefix(1).uppercased() + method.name.dropFirst() + "Observation"
    }
```

Add to `SwiftType`:

```swift
    public var swiftSpelling: String {
        switch self {
        case .simple(let name): name
        case .member(let base, let name): "\(base).\(name)"
        case .optional(let inner): "\(inner.swiftSpelling)?"
        case .array(let element): "[\(element.swiftSpelling)]"
        case .data: "Data"
        }
    }

    /// Stream elements must be named Swift types jextract exports as classes.
    var isBridgeableStreamElement: Bool {
        switch self {
        case .simple(let name): !Self.primitiveTypes.contains(name)
        case .member: true
        case .optional, .array, .data: false
        }
    }
```

- [ ] **Step 4: Teach the analyzer about stream methods**

In `SwiftSourceAnalyzer.swift`, replace the loop body of `extractMethods` after the public check:

```swift
            let methodName = funcDecl.name.text
            let params = extractMethodParams(from: funcDecl.signature.parameterClause)
            let effects = funcDecl.signature.effectSpecifiers

            if effects?.asyncSpecifier != nil {
                let returnType = extractReturnType(from: funcDecl.signature.returnClause)
                methods.append(.init(name: methodName, params: params, returnType: returnType))
                continue
            }

            guard effects?.throwsClause == nil,
                  let stream = extractStream(from: funcDecl.signature.returnClause)
            else { continue }

            guard stream.element.isBridgeableStreamElement else {
                print("warning: '\(methodName)' streams '\(stream.element.swiftSpelling)', which cannot be bridged — skipping")
                continue
            }

            methods.append(.init(
                name: methodName,
                params: params,
                returnType: .init(swiftType: stream.element, isVoid: false),
                kind: .stream(throwing: stream.throwing)
            ))
```

Replace `extractMethodParams` so it records labels:

```swift
    private func extractMethodParams(from clause: FunctionParameterClauseSyntax) -> [BridgeDescriptor.Param] {
        clause.parameters.map { param in
            let name = (param.secondName ?? param.firstName).text
            let label = param.firstName.text == "_" ? nil : param.firstName.text
            return .init(name: name, swiftType: parseSwiftType(param.type), label: label)
        }
    }
```

Add:

```swift
    private func extractStream(from returnClause: ReturnClauseSyntax?) -> (element: SwiftType, throwing: Bool)? {
        guard let identifier = returnClause?.type.as(IdentifierTypeSyntax.self),
              let arguments = identifier.genericArgumentClause?.arguments
        else { return nil }

        let types = arguments.compactMap { argument -> TypeSyntax? in
            if case .type(let type) = argument.argument { return type }
            return nil
        }

        switch identifier.name.text {
        case "AsyncStream" where types.count == 1:
            return (parseSwiftType(types[0]), false)
        case "AsyncThrowingStream" where types.count == 2:
            let failure = types[1].trimmedDescription
            guard failure == "Error" || failure == "any Error" else { return nil }
            return (parseSwiftType(types[0]), true)
        default:
            return nil
        }
    }
```

Update the empty-bridge warning in `extractBridge` to: `has no public async or stream methods — skipping`.

- [ ] **Step 5: Run the analyzer tests**

Run: `cd ~/Projects/swift-android-codegen/swift-macro && swift test --filter BridgeGenTests`
Expected: new stream tests pass; all existing `SwiftSourceAnalyzer` and `KotlinBridgeEmitter` tests still pass.

- [ ] **Step 6: Commit (controller)**

```bash
cd ~/Projects/swift-android-codegen
git add swift-macro/Sources/BridgeGenCore swift-macro/Tests/BridgeGenTests/SwiftSourceAnalyzerStreamTests.swift
git diff --cached
git commit -m "feat: detect AsyncStream methods on bridged types"
```

---

### Task 3: `SwiftStreamEmitter` and the owned output directory

**Files:**
- Create: `swift-macro/Sources/BridgeGenCore/SwiftStreamEmitter.swift`
- Test: `swift-macro/Tests/BridgeGenTests/SwiftStreamEmitterTests.swift`

**Interfaces:**
- Consumes: `Method.kind`, `Param.label`, `SwiftType.swiftSpelling`, `BridgeDescriptor.observationTypeName(for:)`, `hasStreamMethods` (Task 2).
- Produces:
  - `public struct SwiftStreamEmitter { public init(); public func emit(_ bridge: BridgeDescriptor) -> String?; public static func fileName(for bridge: BridgeDescriptor) -> String }` — `nil` when the bridge has no stream methods; file name `<swiftTypeName>+AndroidStreams.swift`.
  - `public enum SwiftStreamOutput { public static func write(_ bridges: [BridgeDescriptor], to directory: URL) throws -> Int }` — creates the directory, deletes every `*+AndroidStreams.swift` already in it (never other files), writes one file per bridge with streams, returns the count written.

- [ ] **Step 1: Write the failing tests**

`swift-macro/Tests/BridgeGenTests/SwiftStreamEmitterTests.swift`:

```swift
import Foundation
import Testing
@testable import BridgeGenCore

@Suite("SwiftStreamEmitter")
struct SwiftStreamEmitterTests {
    let emitter = SwiftStreamEmitter()

    let home = BridgeDescriptor(
        bridgeName: "HomeBridge",
        swiftTypeName: "HomeUseCase",
        methods: [
            .init(name: "fetch", params: [], returnType: .init(swiftType: .simple("HomeOverview"), isVoid: false)),
            .init(
                name: "observe",
                params: [.init(name: "projectId", swiftType: .simple("String"), label: "projectId")],
                returnType: .init(swiftType: .simple("HomeOverview"), isVoid: false),
                kind: .stream(throwing: false)
            ),
        ]
    )

    @Test("Emits a guarded Observation for a plain stream")
    func plainStream() throws {
        let output = try #require(emitter.emit(home))

        #expect(output.hasPrefix("// Generated by bridge-gen from HomeUseCase. Do not edit.\n"))
        #expect(output.contains("#if canImport(SwiftJava)\nimport Foundation\nimport SwiftAndroidCodegen\n"))
        #expect(output.contains("public final class HomeUseCaseObserveObservation: Sendable {"))
        #expect(output.contains("    private let observation: StreamObservation<HomeOverview>"))
        #expect(output.contains("    public init(_ useCase: any HomeUseCase, projectId: String) {"))
        #expect(output.contains("        self.observation = StreamObservation(useCase.observe(projectId: projectId))"))
        #expect(output.contains("    public func next() async -> HomeOverview? {\n        try? await self.observation.next()\n    }"))
        #expect(output.contains("    public func cancel() async {\n        await self.observation.cancel()\n    }"))
        #expect(output.hasSuffix("#endif\n"))
        #expect(!output.contains("fetch"))
    }

    @Test("Throwing streams rethrow from next")
    func throwingStream() throws {
        let bridge = BridgeDescriptor(
            bridgeName: "ListBridge",
            swiftTypeName: "ListUseCase",
            methods: [
                .init(name: "observe", params: [], returnType: .init(swiftType: .simple("ListOverview"), isVoid: false), kind: .stream(throwing: true)),
            ]
        )

        let output = try #require(emitter.emit(bridge))

        #expect(output.contains("    public init(_ useCase: any ListUseCase) {"))
        #expect(output.contains("StreamObservation(useCase.observe())"))
        #expect(output.contains("    public func next() async throws -> ListOverview? {\n        try await self.observation.next()\n    }"))
    }

    @Test("Mirrors external labels")
    func labels() throws {
        let bridge = BridgeDescriptor(
            bridgeName: "SceneBridge",
            swiftTypeName: "SceneUseCase",
            methods: [
                .init(
                    name: "observe",
                    params: [
                        .init(name: "projectId", swiftType: .simple("String"), label: "for"),
                        .init(name: "sceneId", swiftType: .simple("String"), label: nil),
                    ],
                    returnType: .init(swiftType: .simple("Scene"), isVoid: false),
                    kind: .stream(throwing: false)
                ),
            ]
        )

        let output = try #require(emitter.emit(bridge))

        #expect(output.contains("public init(_ useCase: any SceneUseCase, for projectId: String, _ sceneId: String) {"))
        #expect(output.contains("useCase.observe(for: projectId, sceneId)"))
    }

    @Test("Returns nil without stream methods")
    func noStreams() {
        let bridge = BridgeDescriptor(
            bridgeName: "B",
            swiftTypeName: "P",
            methods: [.init(name: "fetch", params: [], returnType: .void)]
        )
        #expect(emitter.emit(bridge) == nil)
    }

    @Test("Output directory is replaced on every run")
    func ownedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-gen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("Old+AndroidStreams.swift")
        try "stale".write(to: stale, atomically: true, encoding: .utf8)
        let unrelated = directory.appendingPathComponent("Handwritten.swift")
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)

        let plain = BridgeDescriptor(bridgeName: "B", swiftTypeName: "P", methods: [.init(name: "fetch", params: [], returnType: .void)])
        let written = try SwiftStreamOutput.write([home, plain], to: directory)

        #expect(written == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == ["Handwritten.swift", "HomeUseCase+AndroidStreams.swift"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/Projects/swift-android-codegen/swift-macro && swift test --filter SwiftStreamEmitter`
Expected: build failure, `cannot find 'SwiftStreamEmitter' in scope`.

- [ ] **Step 3: Implement the emitter and writer**

`swift-macro/Sources/BridgeGenCore/SwiftStreamEmitter.swift`:

```swift
import Foundation

/// Emits the Swift classes that expose a bridged type's stream methods to Kotlin.
public struct SwiftStreamEmitter {
    public init() {}

    public static func fileName(for bridge: BridgeDescriptor) -> String {
        "\(bridge.swiftTypeName)+AndroidStreams.swift"
    }

    /// `nil` when `bridge` has no stream methods.
    public func emit(_ bridge: BridgeDescriptor) -> String? {
        let streams = bridge.methods.filter { if case .stream = $0.kind { true } else { false } }
        guard !streams.isEmpty else { return nil }

        var w = CodeWriter()
        w.line("// Generated by bridge-gen from \(bridge.swiftTypeName). Do not edit.")
        w.line("#if canImport(SwiftJava)")
        w.line("import Foundation")
        w.line("import SwiftAndroidCodegen")
        for method in streams {
            w.line()
            emitObservation(&w, bridge: bridge, method: method)
        }
        w.line("#endif")
        return w.output
    }

    private func emitObservation(_ w: inout CodeWriter, bridge: BridgeDescriptor, method: BridgeDescriptor.Method) {
        guard case let .stream(throwing) = method.kind else { return }
        let element = method.returnType.swiftType.swiftSpelling
        let initParams = (["_ useCase: any \(bridge.swiftTypeName)"] + method.params.map(declaration)).joined(separator: ", ")
        let arguments = method.params.map(argument).joined(separator: ", ")

        w.line("public final class \(bridge.observationTypeName(for: method)): Sendable {")
        w.indented { w in
            w.line("private let observation: StreamObservation<\(element)>")
            w.line()
            w.line("public init(\(initParams)) {")
            w.indented { w in
                w.line("self.observation = StreamObservation(useCase.\(method.name)(\(arguments)))")
            }
            w.line("}")
            w.line()
            if throwing {
                w.line("public func next() async throws -> \(element)? {")
                w.indented { w in w.line("try await self.observation.next()") }
            } else {
                w.line("public func next() async -> \(element)? {")
                w.indented { w in w.line("try? await self.observation.next()") }
            }
            w.line("}")
            w.line()
            w.line("public func cancel() async {")
            w.indented { w in w.line("await self.observation.cancel()") }
            w.line("}")
        }
        w.line("}")
    }

    private func declaration(_ param: BridgeDescriptor.Param) -> String {
        let type = param.swiftType.swiftSpelling
        switch param.label {
        case nil: return "_ \(param.name): \(type)"
        case param.name: return "\(param.name): \(type)"
        case let label?: return "\(label) \(param.name): \(type)"
        }
    }

    private func argument(_ param: BridgeDescriptor.Param) -> String {
        guard let label = param.label else { return param.name }
        return "\(label): \(param.name)"
    }
}

/// Writes generated stream sources into a directory the tool owns.
public enum SwiftStreamOutput {
    static let suffix = "+AndroidStreams.swift"

    /// Deletes every `+AndroidStreams.swift` file in `directory`, then writes one file per bridge with streams.
    @discardableResult
    public static func write(_ bridges: [BridgeDescriptor], to directory: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(Self.suffix) {
            try fm.removeItem(at: directory.appendingPathComponent(name))
        }

        let emitter = SwiftStreamEmitter()
        var written = 0
        for bridge in bridges {
            guard let source = emitter.emit(bridge) else { continue }
            let file = directory.appendingPathComponent(SwiftStreamEmitter.fileName(for: bridge))
            try source.write(to: file, atomically: true, encoding: .utf8)
            written += 1
        }
        return written
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/Projects/swift-android-codegen/swift-macro && swift test --filter BridgeGenTests`
Expected: all `BridgeGenTests` pass.

- [ ] **Step 5: Commit (controller)**

```bash
cd ~/Projects/swift-android-codegen
git add swift-macro/Sources/BridgeGenCore/SwiftStreamEmitter.swift swift-macro/Tests/BridgeGenTests/SwiftStreamEmitterTests.swift
git diff --cached
git commit -m "feat: emit Swift observations for bridged streams"
```

---

### Task 4: Kotlin `Flow` methods and `observationFlow` in the runtime

**Files:**
- Modify: `swift-macro/Sources/BridgeGenCore/KotlinBridgeEmitter.swift`
- Test: `swift-macro/Tests/BridgeGenTests/KotlinBridgeEmitterStreamTests.swift` (new)
- Create: `runtime/src/main/kotlin/dev/anicanon/swiftandroid/codegen/runtime/ObservationFlow.kt`
- Create: `runtime/src/test/kotlin/dev/anicanon/swiftandroid/codegen/runtime/ObservationFlowTest.kt`
- Modify: `runtime/build.gradle.kts`

**Interfaces:**
- Consumes: `Method.kind`, `BridgeDescriptor.observationTypeName(for:)` (Task 2); the Swift class shape from Task 3 (`<P><M>Observation.init(_ useCase: any P, …)`, `next()`, `cancel()`), which jextract exposes to Java as `` <P><M>Observation.`init`(useCase, args…, arena) ``, `next(arena): CompletableFuture<Optional<T>>`, `cancel(): CompletableFuture<Void>`.
- Produces: runtime `fun <T : Any> observationFlow(next: suspend () -> T?, cancel: suspend () -> Unit): Flow<T>` in package `dev.anicanon.swiftandroid.codegen.runtime`; bridge method `fun <name>(<params>): Flow<T>`.

- [ ] **Step 1: Write the failing Kotlin emitter tests**

`swift-macro/Tests/BridgeGenTests/KotlinBridgeEmitterStreamTests.swift`:

```swift
import Testing
@testable import BridgeGenCore

@Suite("KotlinBridgeEmitter streams")
struct KotlinBridgeEmitterStreamTests {
    let emitter = KotlinBridgeEmitter(config: BridgeGenConfig(
        bridgePackage: "com.example.bridge",
        runtimePackage: "com.example.runtime",
        sourcePackage: "com.example.source"
    ))

    let bridge = BridgeDescriptor(
        bridgeName: "HomeUseCaseBridge",
        swiftTypeName: "HomeUseCase",
        methods: [
            .init(
                name: "fetch",
                params: [.init(name: "projectId", swiftType: .simple("String"), label: "projectId")],
                returnType: .init(swiftType: .simple("HomeOverview"), isVoid: false)
            ),
            .init(
                name: "observe",
                params: [.init(name: "projectId", swiftType: .simple("String"), label: "projectId")],
                returnType: .init(swiftType: .simple("HomeOverview"), isVoid: false),
                kind: .stream(throwing: false)
            ),
        ]
    )

    @Test("Emits a cold Flow over the generated Observation")
    func flowMethod() {
        let output = emitter.emit(bridge)

        #expect(output.contains("import kotlinx.coroutines.flow.Flow"))
        #expect(output.contains("import kotlinx.coroutines.flow.emitAll"))
        #expect(output.contains("import kotlinx.coroutines.flow.flow"))
        #expect(output.contains("import com.example.runtime.observationFlow"))
        #expect(output.contains("import com.example.source.HomeUseCaseObserveObservation"))
        #expect(output.contains("import com.example.source.HomeOverview"))
        #expect(output.contains("""
            fun observe(projectId: String): Flow<HomeOverview> = flow {
                val observation = withContext(Dispatchers.IO) {
                    HomeUseCaseObserveObservation.`init`(homeUseCase, projectId, arena)
                }
                emitAll(
                    observationFlow(
                        next = {
                            withContext(Dispatchers.IO) {
                                observation.next(arena)
                                    .await()
                                    .orElse(null)
                            }
                        },
                        cancel = {
                            withContext(Dispatchers.IO) {
                                observation.cancel()
                                    .await()
                            }
                        },
                    ),
                )
            }
        """))
        #expect(output.contains("suspend fun fetch(projectId: String): HomeOverview ="))
    }

    @Test("Bridges without streams import no Flow types")
    func noStreams() {
        let plain = BridgeDescriptor(
            bridgeName: "PlainBridge",
            swiftTypeName: "PlainUseCase",
            methods: [.init(name: "fetch", params: [], returnType: .init(swiftType: .simple("Item"), isVoid: false))]
        )
        let output = emitter.emit(plain)

        #expect(!output.contains("kotlinx.coroutines.flow"))
        #expect(!output.contains("observationFlow"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd ~/Projects/swift-android-codegen/swift-macro && swift test --filter "KotlinBridgeEmitter streams"`
Expected: FAIL (`fun observe(` not present; the stream method is currently emitted as a `suspend fun`).

- [ ] **Step 3: Implement the Kotlin stream branch**

In `KotlinBridgeEmitter.swift`:

1. In `emit(_:)`, replace the method loop:

```swift
        for (i, method) in bridge.methods.enumerated() {
            if i > 0 { w.line() }
            switch method.kind {
            case .async:
                emitMethod(&w, method: method, wrappedName: bridge.wrappedName)
            case .stream:
                emitStreamMethod(&w, method: method, bridge: bridge)
            }
        }
```

2. In `collectImports`, after the `for method in bridge.methods` loop, add:

```swift
        if bridge.hasStreamMethods {
            imports.append("kotlinx.coroutines.flow.Flow")
            imports.append("kotlinx.coroutines.flow.emitAll")
            imports.append("kotlinx.coroutines.flow.flow")
            imports.append(config.runtimePackage + ".observationFlow")
            for method in bridge.methods where method.kind != .async {
                imports.append(config.sourcePackage + "." + bridge.observationTypeName(for: method))
            }
        }
```

3. Extract the parameter list and argument helpers used by both method kinds (replace the inline code in `emitMethod` and `emitMethodCall` with calls to these):

```swift
    private func parameterList(_ method: BridgeDescriptor.Method) -> String {
        let declarations = method.params.map { "\($0.name): \($0.swiftType.kotlinType)" }
        return declarations.count > 2
            ? "\n        " + declarations.joined(separator: ",\n        ") + ",\n    "
            : declarations.joined(separator: ", ")
    }

    private func kotlinArguments(_ method: BridgeDescriptor.Method) -> [String] {
        method.params.map { param in
            if param.swiftType.isData {
                "Data.fromByteArray(\(param.name), arena)"
            } else if param.swiftType.isArray {
                "\(param.name).toTypedArray()"
            } else {
                param.name
            }
        }
    }
```

4. Add:

```swift
    private func emitStreamMethod(_ w: inout CodeWriter, method: BridgeDescriptor.Method, bridge: BridgeDescriptor) {
        let element = method.returnType.swiftType.kotlinType
        let observationType = bridge.observationTypeName(for: method)
        let arguments = ([bridge.wrappedName] + kotlinArguments(method) + ["arena"]).joined(separator: ", ")

        w.indented { w in
            w.line("fun \(method.name)(\(parameterList(method))): Flow<\(element)> = flow {")
            w.indented { w in
                w.line("val observation = withContext(Dispatchers.IO) {")
                w.indented { w in w.line("\(observationType).`init`(\(arguments))") }
                w.line("}")
                w.line("emitAll(")
                w.indented { w in
                    w.line("observationFlow(")
                    w.indented { w in
                        w.line("next = {")
                        w.indented { w in
                            w.line("withContext(Dispatchers.IO) {")
                            w.indented { w in
                                w.line("observation.next(arena)")
                                w.line("    .await()")
                                w.line("    .orElse(null)")
                            }
                            w.line("}")
                        }
                        w.line("},")
                        w.line("cancel = {")
                        w.indented { w in
                            w.line("withContext(Dispatchers.IO) {")
                            w.indented { w in
                                w.line("observation.cancel()")
                                w.line("    .await()")
                            }
                            w.line("}")
                        }
                        w.line("},")
                    }
                    w.line("),")
                }
                w.line(")")
            }
            w.line("}")
        }
    }
```

`method.kind != .async` needs `Kind: Equatable` (Task 2 declares it).

- [ ] **Step 4: Run the Swift tests**

Run: `cd ~/Projects/swift-android-codegen/swift-macro && swift test --filter BridgeGenTests`
Expected: all pass, including the pre-existing `KotlinBridgeEmitter` tests (the refactor into `parameterList`/`kotlinArguments` must not change their output).

- [ ] **Step 5: Write the failing runtime test**

Add to `runtime/build.gradle.kts`:

```kotlin
dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.1")
    compileOnly("org.swift.swiftkit:swiftkit-core:1.0-0bdba49")
    testImplementation(kotlin("test"))
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.1")
}

tasks.test {
    useJUnitPlatform()
}
```

(Keep the existing comment above `compileOnly`; if `repositories { mavenLocal() }` cannot resolve kotlin-test/coroutines-test, add `mavenCentral()` to that block.)

`runtime/src/test/kotlin/dev/anicanon/swiftandroid/codegen/runtime/ObservationFlowTest.kt`:

```kotlin
package dev.anicanon.swiftandroid.codegen.runtime

import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ObservationFlowTest {
    private class Source(private val items: List<Int>, private val failure: Throwable? = null) {
        private var index = 0
        var cancels = 0

        suspend fun next(): Int? {
            if (index < items.size) return items[index++]
            failure?.let { throw it }
            return null
        }

        suspend fun cancel() {
            cancels++
        }
    }

    @Test
    fun emitsUntilNullAndCancelsOnce() = runTest {
        val source = Source(listOf(1, 2))
        assertEquals(listOf(1, 2), observationFlow(source::next, source::cancel).toList())
        assertEquals(1, source.cancels)
    }

    @Test
    fun earlyTerminationCancelsOnce() = runTest {
        val source = Source(listOf(1, 2, 3))
        assertEquals(1, observationFlow(source::next, source::cancel).first())
        assertEquals(1, source.cancels)
    }

    @Test
    fun failureRethrowsAndCancelsOnce() = runTest {
        val source = Source(listOf(1), IllegalStateException("boom"))
        val error = assertFailsWith<IllegalStateException> {
            observationFlow(source::next, source::cancel).toList()
        }
        assertEquals("boom", error.message)
        assertEquals(1, source.cancels)
    }

    @Test
    fun collectorCancellationCancelsOnce() = runTest {
        var cancels = 0
        val flow = observationFlow<Int>(next = { awaitCancellation() }, cancel = { cancels++ })
        val job = launch { flow.collect {} }
        runCurrent()
        job.cancelAndJoin()
        assertEquals(1, cancels)
    }
}
```

- [ ] **Step 6: Run to verify failure**

Run: `cd ~/Projects/swift-android-codegen && ./gradlew :runtime:test`
Expected: compilation failure, `Unresolved reference: observationFlow`.

- [ ] **Step 7: Add `observationFlow` to the runtime**

`runtime/src/main/kotlin/dev/anicanon/swiftandroid/codegen/runtime/ObservationFlow.kt`:

```kotlin
package dev.anicanon.swiftandroid.codegen.runtime

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext

/** Emits until [next] returns null; [cancel] always runs once, also when the collector is cancelled. */
fun <T : Any> observationFlow(next: suspend () -> T?, cancel: suspend () -> Unit): Flow<T> = flow {
    try {
        while (true) {
            emit(next() ?: break)
        }
    } finally {
        withContext(NonCancellable) { cancel() }
    }
}
```

- [ ] **Step 8: Run the runtime tests**

Run: `cd ~/Projects/swift-android-codegen && ./gradlew :runtime:test`
Expected: 4 tests pass.

- [ ] **Step 9: Commit (controller)**

```bash
cd ~/Projects/swift-android-codegen
git add swift-macro/Sources/BridgeGenCore/KotlinBridgeEmitter.swift swift-macro/Tests/BridgeGenTests/KotlinBridgeEmitterStreamTests.swift runtime
git diff --cached
git commit -m "feat: bridge streams to Kotlin Flow"
```

---

### Task 5: CLI option, Gradle property, README and version

**Files:**
- Modify: `swift-macro/Sources/BridgeGen/BridgeGenCommand.swift`
- Modify: `gradle-plugin/src/main/java/dev/anicanon/swiftandroid/codegen/gradle/SwiftAndroidCodegenExtension.java`
- Modify: `gradle-plugin/src/main/java/dev/anicanon/swiftandroid/codegen/gradle/GenerateSwiftAndroidBridgesTask.java`
- Modify: `gradle-plugin/src/main/java/dev/anicanon/swiftandroid/codegen/gradle/SwiftAndroidCodegenPlugin.java`
- Modify: `README.md`
- Modify: `build.gradle.kts` (version)

**Interfaces:**
- Consumes: `SwiftStreamOutput.write(_:to:)` (Task 3).
- Produces: CLI flag `--swift-output-dir <path>`; Gradle `swiftAndroidCodegen { swiftOutputDir.set(...) }`.

- [ ] **Step 1: CLI flag**

In `BridgeGenCommand`, add the option:

```swift
    @Option(help: "Directory for generated Swift stream observations. Its +AndroidStreams.swift files are replaced on every run.")
    var swiftOutputDir: String?
```

At the end of `run()`, after the Kotlin loop's `print`:

```swift
        if let swiftOutputDir {
            let written = try SwiftStreamOutput.write(bridges, to: URL(fileURLWithPath: swiftOutputDir))
            print("Generated \(written) stream observation file(s) in \(swiftOutputDir)")
        }
```

- [ ] **Step 2: Smoke-test the CLI on a fixture**

```bash
S=$(mktemp -d "$HOME/.bridge-gen-smoke.XXXX")
mkdir -p "$S/src"
cat > "$S/src/Home.swift" <<'EOF'
@AndroidBridge("HomeUseCaseBridge")
public protocol HomeUseCase: Sendable {
    func fetch(projectId: String) async -> HomeOverview
    func observe(projectId: String) -> AsyncStream<HomeOverview>
}
EOF
cd ~/Projects/swift-android-codegen/swift-macro
swift run bridge-gen --source-dir "$S/src" --output-dir "$S/kt" --bridge-package com.example.bridge --source-package com.example.source --swift-output-dir "$S/swift"
cat "$S/swift/HomeUseCase+AndroidStreams.swift" "$S/kt/com/example/bridge/HomeUseCaseBridge.kt"
rm -rf "$S"
```

Expected: both files print; the Swift file contains `HomeUseCaseObserveObservation`, the Kotlin file contains `fun observe(projectId: String): Flow<HomeOverview> = flow {`.

- [ ] **Step 3: Gradle property**

`SwiftAndroidCodegenExtension.java` — add:

```java
    /** Directory for generated Swift stream observations; bridge-gen replaces its +AndroidStreams.swift files. */
    public abstract DirectoryProperty getSwiftOutputDir();
```

`GenerateSwiftAndroidBridgesTask.java` — add the property and pass it:

```java
    @Optional @OutputDirectory
    public abstract DirectoryProperty getSwiftOutputDir();
```

and in `generate()`, before `getExecOperations().exec(...)`:

```java
        if (getSwiftOutputDir().isPresent()) {
            args.add("--swift-output-dir");
            args.add(getSwiftOutputDir().get().getAsFile().getAbsolutePath());
        }
```

`SwiftAndroidCodegenPlugin.java` — in the task configuration lambda:

```java
                    task.getSwiftOutputDir().set(extension.getSwiftOutputDir());
```

Run: `cd ~/Projects/swift-android-codegen && ./gradlew :gradle-plugin:build`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: README and version**

- `build.gradle.kts`: `version = "0.4.0"`.
- README: update every `0.2.0`/`0.3.0` version reference in setup snippets to `0.4.0`; add `swiftOutputDir.set(file("../Shared/Sources/MySharedCode/Generated/AndroidStreams"))` to the `swiftAndroidCodegen { }` example with a one-line note that the directory is owned by the tool; add a `## Streams` section after "Use from Android":

````markdown
## Streams

A non-async method returning `AsyncStream<T>` or `AsyncThrowingStream<T, Error>` becomes a cold Kotlin `Flow<T>`:

```swift
@AndroidBridge("HomeUseCaseBridge")
public protocol HomeUseCase: Sendable {
    func observe(projectId: String) -> AsyncStream<HomeOverview>
}
```

```kotlin
bridge.observe(projectId).collect { overview -> /* ... */ }
```

- `bridge-gen` writes `HomeUseCase+AndroidStreams.swift` (a `HomeUseCaseObserveObservation` class) into `swiftOutputDir`. Commit it, and add that directory to jextract's `swiftFilterInclude`. Run `generateSwiftAndroidBridges` before jextract.
- The stream requirement needs no `#if` guard: jextract skips it with a warning and exports the generated class instead.
- Collection starts the Swift stream; completion, `first()`/`take()` and collector cancellation all stop it, which runs its `onTermination`.
- A throwing stream's error fails the flow. `T` must be a named type jextract exports; `String`, primitives, arrays, optionals and `Data` are skipped with a warning.
- Generated Swift is wrapped in `#if canImport(SwiftJava)`, so iOS builds never compile it.
````

- Type mappings table: add a row `| `AsyncStream<T>` / `AsyncThrowingStream<T, Error>` | `Flow<T>` |`.
- "The runtime is a single file" sentence: replace with "The runtime provides `CompletableFuture<T>.await()` and `observationFlow`, which backs generated stream methods."
- "What the analyzer captures": add a bullet: "**Stream methods** — non-async methods returning `AsyncStream`/`AsyncThrowingStream` become `Flow`-returning functions."

- [ ] **Step 5: Full codegen verification**

```bash
cd ~/Projects/swift-android-codegen/swift-macro && swift test
cd ~/Projects/swift-android-codegen && swift build && ./gradlew build
```

Expected: all Swift tests pass (macro, BridgeGen, StreamObservation); root manifest builds; Gradle build (runtime tests + plugin) succeeds.

- [ ] **Step 6: Commit (controller)**

```bash
cd ~/Projects/swift-android-codegen
git add swift-macro/Sources/BridgeGen gradle-plugin README.md build.gradle.kts
git diff --cached
git commit -m "feat: write stream observations from the CLI and Gradle task"
```

---

### Task 6: Wire the generator into the Android build (app repo)

**Files:**
- Modify: `Android/app/build.gradle.kts`
- Modify: `Shared/Sources/AnicanonShared/swift-java.config`

**Interfaces:**
- Produces: generated Swift lands in `Shared/Sources/AnicanonShared/Generated/AndroidStreams/`; `generateBridges` runs `generateSwiftAndroidBridges` before `swiftBindingsBuildDebug`.

- [ ] **Step 1: Branch**

```bash
cd ~/Projects/anicanon-companion && git checkout main && git pull --ff-only && git checkout -b feature/generated-stream-observations
```

- [ ] **Step 2: Configure the output directory and ordering**

In `Android/app/build.gradle.kts`, inside `swiftAndroidCodegen { }` add:

```kotlin
    swiftOutputDir.set(sharedSwiftPackageDir.resolve("Sources/AnicanonShared/Generated/AndroidStreams"))
```

After the `tasks.register("generateBridges")` block add:

```kotlin
// Generated stream observations are Swift sources jextract must see.
tasks.matching { it.name.startsWith("swiftBindingsBuild") }.configureEach {
    mustRunAfter("generateSwiftAndroidBridges")
}
```

- [ ] **Step 3: Let jextract read the generated directory**

In `Shared/Sources/AnicanonShared/swift-java.config`, add `"Generated/**"` to `swiftFilterInclude`.

- [ ] **Step 4: Verify the build script resolves the local plugin**

```bash
export SWIFT_ANDROID_CODEGEN_PATH=$HOME/Projects/swift-android-codegen
cd ~/Projects/anicanon-companion/Android && ./gradlew :app:help -q
```

Expected: no "Unresolved reference: swiftOutputDir" (the sibling codegen checkout is used through `includeBuild`). Do not commit yet; Task 7 regenerates and commits together.

---

### Task 7: Replace the three hand-written Observations (app repo)

**Files:**
- Modify: `Shared/Sources/AnicanonShared/Features/ProjectList/ProjectListUseCase.swift`
- Modify: `Shared/Sources/AnicanonShared/Features/ProjectDetail/Home/ProjectDetailHomeOverviewUseCase.swift`
- Modify: `Shared/Sources/AnicanonShared/Features/ProjectDetail/Gallery/ProjectDetailGalleryOverviewUseCase.swift`
- Modify: `Shared/Sources/AnicanonShared/Internals/Features/ProjectList/ProjectListUseCase+Stubs.swift`
- Modify: `Shared/Sources/AnicanonShared/Internals/Features/ProjectDetail/Home/ProjectDetailHomeOverviewUseCase+Stubs.swift`
- Modify: `Shared/Sources/AnicanonShared/Internals/Features/ProjectDetail/Gallery/ProjectDetailGalleryOverviewUseCase+Stubs.swift`
- Create (generated): `Shared/Sources/AnicanonShared/Generated/AndroidStreams/{ProjectListUseCase,ProjectDetailHomeOverviewUseCase,ProjectDetailGalleryOverviewUseCase}+AndroidStreams.swift`
- Modify (generated): `Android/app/src/generated/bridges/.../{ProjectListUseCaseBridge,ProjectDetailHomeOverviewUseCaseBridge,ProjectDetailGalleryOverviewUseCaseBridge}.kt`
- Delete (orphans): `Android/app/src/generated/bridges/app/anicanon/companion/core/bridge/generated/{ProjectListOverviewObservationBridge,ProjectDetailHomeOverviewObservationBridge,ProjectDetailGalleryOverviewObservationBridge}.kt`, and any `Android/app/src/generated/swiftjava/**/{ProjectListOverviewObservation,ProjectDetailHomeOverviewObservation,ProjectDetailGalleryOverviewObservation}*` files
- Delete: `Android/app/src/main/java/app/anicanon/companion/core/runtime/ObservationFlow.kt`
- Delete: `Android/app/src/main/java/app/anicanon/companion/features/projects/ProjectListOverviews.kt`
- Delete: `Android/app/src/main/java/app/anicanon/companion/features/projectdetail/home/ProjectDetailHomeOverviews.kt`
- Delete: `Android/app/src/main/java/app/anicanon/companion/features/projectdetail/gallery/ProjectDetailGalleryOverviews.kt`
- Modify: `Android/app/src/main/java/app/anicanon/companion/features/projects/ProjectsViewModel.kt:76`
- Modify: `Android/app/src/main/java/app/anicanon/companion/features/projectdetail/home/ProjectDetailHomeViewModel.kt:35`
- Modify: `Android/app/src/main/java/app/anicanon/companion/features/projectdetail/gallery/ProjectDetailGalleryViewModel.kt:36`

**Interfaces:**
- Consumes: generated bridge methods `ProjectListUseCaseBridge.observe(): Flow<ProjectListOverview>`, `ProjectDetailHomeOverviewUseCaseBridge.observe(projectId: String): Flow<ProjectDetailHomeOverview>`, `ProjectDetailGalleryOverviewUseCaseBridge.observe(projectId: String): Flow<ProjectDetailGalleryOverview>`.

- [ ] **Step 1: Project list use case**

In `ProjectListUseCase.swift`:
- Protocol: delete `func makeObservation() async -> ProjectListOverviewObservation` and the `#if !os(Android)` / `#endif` around `func observe() -> AsyncThrowingStream<ProjectListOverview, Error>`.
- Delete the `#if !os(Android) extension ProjectListUseCase { makeObservation } #endif` block.
- `DefaultProjectListUseCase`: remove the `#if !os(Android)` / `#endif` around `observe()`; delete `makeObservation()`.
- Delete the `@AndroidBridge("ProjectListOverviewObservationBridge") public final class ProjectListOverviewObservation` class and the `private actor ProjectListOverviewObservationState`.

- [ ] **Step 2: Home and gallery use cases**

Same edits in `ProjectDetailHomeOverviewUseCase.swift` (`makeObservation(projectId:)`, `ProjectDetailHomeOverviewObservation`, `ProjectDetailHomeOverviewObservationState`) and `ProjectDetailGalleryOverviewUseCase.swift` (`makeObservation(projectId:)`, `ProjectDetailGalleryOverviewObservation`, `ProjectDetailGalleryOverviewObservationState`): un-guard `observe(projectId:)` on the protocol and on the `Default…` type, delete `makeObservation` everywhere, delete the Observation class and its state actor.

- [ ] **Step 3: Stubs**

In the three `+Stubs.swift` files: delete `makeObservation(...)`; remove the `#if !os(Android)` / `#endif` around `observe(...)` in the home and gallery stubs (the project list stub's `observe()` is already un-guarded).

- [ ] **Step 4: Confirm nothing else references the removed types**

Run: `cd ~/Projects/anicanon-companion && grep -rn "makeObservation\|OverviewObservation\b\|OverviewObservationState" Shared/Sources iOS/Companion Android/app/src/main --include='*.swift' --include='*.kt' | grep -v /generated/`
Expected: no output.

- [ ] **Step 5: Regenerate**

```bash
export SWIFT_ANDROID_CODEGEN_PATH=$HOME/Projects/swift-android-codegen
cd ~/Projects/anicanon-companion/Android
rm -f app/src/generated/bridges/app/anicanon/companion/core/bridge/generated/{ProjectListOverviewObservationBridge,ProjectDetailHomeOverviewObservationBridge,ProjectDetailGalleryOverviewObservationBridge}.kt
./gradlew generateBridges
```

Then remove orphaned accessor files for the deleted Swift classes:

```bash
find app/src/generated/swiftjava -name 'Project*OverviewObservation*' -print -delete
```

Expected: `Shared/Sources/AnicanonShared/Generated/AndroidStreams/` holds exactly three `+AndroidStreams.swift` files; the three `*UseCaseBridge.kt` files each gain `fun observe(...): Flow<...> = flow {`; `git status` shows no other generated files changing except the new Observation accessors, if the accessor plugin emits them. If unrelated generated files churn (known jextract non-determinism), restore them with `git checkout -- <path>`.

- [ ] **Step 6: Android callers**

Delete `core/runtime/ObservationFlow.kt`, `features/projects/ProjectListOverviews.kt`, `features/projectdetail/home/ProjectDetailHomeOverviews.kt`, `features/projectdetail/gallery/ProjectDetailGalleryOverviews.kt`.

Edit the call sites:
- `ProjectsViewModel.kt:76`: `projectListUseCase.overviews().collect { overview ->` → `projectListUseCase.observe().collect { overview ->`
- `ProjectDetailHomeViewModel.kt:35`: `overviewUseCase.overviews(projectId).collect { overview ->` → `overviewUseCase.observe(projectId).collect { overview ->`
- `ProjectDetailGalleryViewModel.kt:36`: same change as home.

Remove any now-unused imports in those three files.

- [ ] **Step 7: Build verification (no tests yet)**

```bash
export SWIFT_ANDROID_CODEGEN_PATH=$HOME/Projects/swift-android-codegen
cd ~/Projects/anicanon-companion/Android && ./gradlew :app:assembleDebug
./gradlew :app:checkFileLength
```

Run `assembleDebug` as its own command, separate from `generateBridges`. Expected: BUILD SUCCESSFUL for both. If Gradle reports an implicit dependency between `generateSwiftAndroidBridges` and `swiftBindingsBuild*`, replace the `mustRunAfter` block from Task 6 with `tasks.named("generateBridges") { ... }`-scoped ordering via `dependsOn` so only `generateBridges` triggers generation.

- [ ] **Step 8: Commit (controller)**

```bash
cd ~/Projects/anicanon-companion
git status --short Shared/Package.resolved   # the local codegen path can rewrite it; restore with git checkout -- Shared/Package.resolved
git add -A Shared/Sources Android/app
git diff --cached --stat
git diff --cached -- Shared/Sources/AnicanonShared/Generated
git commit -m "refactor(shared): generate stream observations for project list, home and gallery"
```

---

### Task 8: Platform verification (app repo)

**Files:** none (verification only).

- [ ] **Step 1: Shared tests (macOS)**

Run: `cd ~/Projects/anicanon-companion/Shared && SWIFT_ANDROID_CODEGEN_PATH=$HOME/Projects/swift-android-codegen swift test --filter "ProjectRemoteExistenceTests|ClientStubTests"`
Expected: PASS. These are the suites that exercise the three use cases and their stubs; generated files are excluded on macOS by `#if canImport(SwiftJava)`.

- [ ] **Step 2: Android unit tests, scoped**

Run: `cd ~/Projects/anicanon-companion/Android && SWIFT_ANDROID_CODEGEN_PATH=$HOME/Projects/swift-android-codegen ./gradlew :app:testDebugUnitTest --tests '*ProjectsViewModelTest' --tests '*ProjectDetailHomeViewModelTest'`
Expected: PASS. Gallery has no ViewModel test; it is covered by the build and the manual check. This also builds the JVM test-support library, which compiles the generated observations.

- [ ] **Step 3: iOS build**

Run: `cd ~/Projects/anicanon-companion/iOS && xcodebuild build -project Companion.xcodeproj -scheme Companion -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipMacroValidation -quiet`
Expected: BUILD SUCCEEDED. iOS still resolves codegen 0.3.0 and never compiles the generated files. No iOS test run: iOS behaviour is unchanged (it already consumed `observe`).

- [ ] **Step 4: Manual emulator check**

Install `assembleDebug` on the emulator; open the projects list, a project's home and its gallery. Each loads and updates when data changes (e.g. follow/unfollow on the list). For each of the three screens, leave it (back or tab away) and re-enter it, confirming it still loads and updates without crashes.

- [ ] **Step 5: Report**

Record the four results (commands + outcome) for the PR bodies.

---

### Task 9: Release 0.4.0 and pin it (both repos; ask the user before each outward step, in this order)

The steps below are strictly ordered: the codegen PR merges and 0.4.0 is tagged and fully published
*before* any app-repo pin commit is made, and the app PR opens only after the app has been verified
against the published 0.4.0 with no local override. Do not reorder — an app pin against an unpublished
or partially-published version cannot resolve.

- [ ] **Step 1: Codegen PR merged** — ask the user, then push `feature/asyncstream-flow-bridges` and open `[FEATURE] Bridge AsyncStream to Kotlin Flow` with Summary + Verification (Task 5 Step 5 output). Ask the user before merging.
- [ ] **Step 2: Tag and publish 0.4.0 (all three artifacts)** — after merge and with the user's go-ahead: tag `0.4.0` on `main` and publish to GitHub Packages from this machine (`./gradlew publish`). This must publish all of: the runtime, the Gradle plugin, and the plugin marker artifact — all three are consumed on the Android/Gradle side (`libs.versions.toml` resolves the runtime coordinate directly, `build.gradle.kts`'s `id("dev.anicanon.swift-android-codegen")` resolves the plugin via its marker), so a partial publish leaves Android's Gradle build unable to resolve 0.4.0 even though `Shared/Package.swift` (SwiftPM, resolving the git tag, not Maven) is unaffected. If the publish half-fails with a 409 (jar without POM), delete that version with `gpr.key` and re-run; do not burn a version number.
- [ ] **Step 3: Pin in the app (one commit, only after Step 2 is confirmed published)**
  - `Shared/Package.swift`: `let swiftAndroidCodegenVersion = Version(0, 4, 0)`
  - `Shared/Package.resolved`: re-resolved, not hand-edited (see below).
  - `iOS/Companion.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`: re-resolved, not hand-edited (see below).
  - `Android/gradle/libs.versions.toml`: `swiftAndroidCodegen = "0.4.0"` (currently `0.2.4`).
  - `Android/app/build.gradle.kts`: `id("dev.anicanon.swift-android-codegen") version "0.4.0"` (currently `0.3.0`).
  - Resolve, don't hand-edit the lockfiles: `cd Shared && swift package update swift-android-codegen` (updates `Shared/Package.resolved`); open the Xcode project (or `xcodebuild -resolvePackageDependencies`) so it re-resolves `iOS/Companion.xcodeproj/.../Package.resolved` too.
  - All five files land in a single commit: `build: pin swift-android-codegen 0.4.0`.
- [ ] **Step 4: Verify the pin with no local override** — `unset SWIFT_ANDROID_CODEGEN_PATH`, then `cd Android && ./gradlew :app:assembleDebug` and the iOS build from Task 8 Step 3. Both must succeed resolving 0.4.0 from GitHub Packages alone, with no `SWIFT_ANDROID_CODEGEN_PATH` pointing at a local checkout.
- [ ] **Step 5: App PR** — only once Step 4 passes: ask the user, then push `feature/generated-stream-observations` and open `[FEATURE] Generated stream observations` with Summary, Verification (Task 8 results plus Step 4 of this task) and "Media: Not attached" (no UI change). Ask the user before merging.
