import Testing
@testable import BridgeGenCore

@Suite("SwiftSourceAnalyzer")
struct SwiftSourceAnalyzerTests {
    let analyzer = SwiftSourceAnalyzer()

    @Test("Extracts bridge from annotated UseCase")
    func useCaseBridge() {
        let source = """
        import Foundation
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
                fatalError()
            }
        }
        """

        let bridges = analyzer.analyzeSource(source)
        #expect(bridges.count == 1)

        let bridge = bridges[0]
        #expect(bridge.bridgeName == "ProjectListBridge")
        #expect(bridge.swiftTypeName == "DefaultProjectListUseCase")

        #expect(bridge.initParams.count == 2)
        #expect(bridge.initParams[0].name == "projectClient")
        #expect(bridge.initParams[0].swiftType.kotlinType == "ProjectClient")
        #expect(bridge.initParams[1].name == "profileClient")
        #expect(bridge.initParams[1].swiftType.kotlinType == "ProfileClient")

        #expect(bridge.methods.count == 1)
        #expect(bridge.methods[0].name == "fetch")
        #expect(bridge.methods[0].params.isEmpty)
        #expect(bridge.methods[0].returnType.swiftType.kotlinType == "ProjectListOverview")
    }

    @Test("Extracts bridge from annotated client")
    func clientBridge() {
        let source = """
        @AndroidBridge("BackdropCreationBridge")
        public struct RemoteBackdropClient: BackdropClient {
            private let api: APIClient

            public init(api: APIClient) {
                self.api = api
            }

            public func listBackdrops(projectId: String) async throws -> [Backdrop] {
                fatalError()
            }

            public func createBackdrop(projectId: String, payload: CreateBackdropPayload) async throws -> Backdrop {
                fatalError()
            }
        }
        """

        let bridges = analyzer.analyzeSource(source)
        #expect(bridges.count == 1)

        let bridge = bridges[0]
        #expect(bridge.bridgeName == "BackdropCreationBridge")
        #expect(bridge.initParams.count == 1)
        #expect(bridge.initParams[0].name == "api")
        #expect(bridge.initParams[0].swiftType.kotlinType == "APIClient")

        #expect(bridge.methods.count == 2)
        #expect(bridge.methods[0].name == "listBackdrops")
        #expect(bridge.methods[0].returnType.swiftType.isArray)
        #expect(bridge.methods[1].name == "createBackdrop")
        #expect(bridge.methods[1].params[1].swiftType.kotlinType == "CreateBackdropPayload")
    }

    @Test("Handles Data params → ByteArray")
    func dataParams() {
        let source = """
        @AndroidBridge("FaceSheetBridge")
        public struct DefaultGenerateFaceSheetUseCase: GenerateFaceSheetUseCase {
            private let assetClient: any AssetClient

            public init(assetClient: any AssetClient) {
                self.assetClient = assetClient
            }

            public func generate(projectId: String, characterId: String, imageData: Data) async throws -> FaceSheetSession {
                fatalError()
            }
        }
        """

        let bridges = analyzer.analyzeSource(source)
        let method = bridges[0].methods[0]
        #expect(method.params[2].name == "imageData")
        #expect(method.params[2].swiftType.kotlinType == "ByteArray")
        #expect(method.params[2].swiftType.isData)
    }

    @Test("Handles optional params")
    func optionalParams() {
        let source = """
        @AndroidBridge("TestBridge")
        public struct TestUseCase: Sendable {
            public init() {}

            public func doSomething(name: String, description: String?) async throws -> String {
                fatalError()
            }
        }
        """

        let bridges = analyzer.analyzeSource(source)
        let method = bridges[0].methods[0]
        #expect(method.params[1].name == "description")
        #expect(method.params[1].swiftType.kotlinType == "String?")
    }

    @Test("Ignores unannotated types")
    func ignoresUnannotated() {
        let source = """
        public struct RemoteProjectClient: ProjectClient {
            public init(api: APIClient) {}
            public func listProjects() async throws -> [Project] { fatalError() }
        }
        """

        let bridges = analyzer.analyzeSource(source)
        #expect(bridges.isEmpty)
    }

    @Test("Ignores non-async methods")
    func ignoresNonAsync() {
        let source = """
        @AndroidBridge("TestBridge")
        public struct TestType: Sendable {
            public init() {}
            public func syncMethod() -> String { "" }
            public func asyncMethod() async throws -> String { "" }
        }
        """

        let bridges = analyzer.analyzeSource(source)
        #expect(bridges[0].methods.count == 1)
        #expect(bridges[0].methods[0].name == "asyncMethod")
    }

    @Test("Handles void return")
    func voidReturn() {
        let source = """
        @AndroidBridge("TokenBridge")
        public struct RemoteDeviceTokenClient: DeviceTokenClient {
            private let api: APIClient
            public init(api: APIClient) { self.api = api }
            public func registerToken(_ token: String) async throws {
            }
        }
        """

        let bridges = analyzer.analyzeSource(source)
        #expect(bridges[0].methods[0].returnType.isVoid)
    }

    @Test("Extracts multiple bridges from one file")
    func multipleBridgesInOneFile() {
        let source = """
        @AndroidBridge("SuggestBridge")
        public struct DefaultSuggestUseCase: SuggestUseCase {
            private let client: any StudioClient
            public init(studioClient: any StudioClient) { self.client = studioClient }
            public func execute(projectId: String) async throws -> SuggestResponse { fatalError() }
        }

        @AndroidBridge("GenerateBridge")
        public struct DefaultGenerateUseCase: GenerateUseCase {
            private let client: any StudioClient
            public init(studioClient: any StudioClient) { self.client = studioClient }
            public func execute(projectId: String) async throws -> Job { fatalError() }
        }
        """

        let bridges = analyzer.analyzeSource(source)
        #expect(bridges.count == 2)
        #expect(bridges[0].bridgeName == "SuggestBridge")
        #expect(bridges[1].bridgeName == "GenerateBridge")
    }
}
