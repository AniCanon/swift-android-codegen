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

    @Test("Accepts Swift.Error as the throwing stream failure")
    func swiftErrorFailure() throws {
        let bridges = analyzer.analyzeSource("""
        @AndroidBridge("ListBridge")
        public protocol ListUseCase: Sendable {
            func observe() -> AsyncThrowingStream<ListOverview, Swift.Error>
        }
        """)

        #expect(bridges.first?.methods.first?.kind == .stream(throwing: true))
    }

    @Test("Streams are only bridged on protocols; a class or struct bridge keeps its async methods and skips streams")
    func streamsSkippedOnStructBridge() throws {
        let bridges = analyzer.analyzeSource("""
        @AndroidBridge("HomeBridge")
        public struct HomeUseCase: Sendable {
            public func fetch(projectId: String) async -> HomeOverview { fatalError() }
            public func observe(projectId: String) -> AsyncStream<HomeOverview> { fatalError() }
        }
        """)

        let bridge = try #require(bridges.first)
        #expect(bridge.methods.map(\.name) == ["fetch"])
        #expect(bridge.methods[0].kind == .async)
        #expect(!bridge.hasStreamMethods)
    }

    @Test("Keeps the first of two stream overloads and skips the rest")
    func duplicateStreamMethodNamesKeepsFirst() throws {
        let bridges = analyzer.analyzeSource("""
        @AndroidBridge("HomeBridge")
        public protocol HomeUseCase: Sendable {
            func observe(projectId: String) -> AsyncStream<HomeOverview>
            func observe(sceneId: String) -> AsyncStream<HomeOverview>
        }
        """)

        let bridge = try #require(bridges.first)
        #expect(bridge.methods.count == 1)
        #expect(bridge.methods[0].params.map(\.name) == ["projectId"])
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
