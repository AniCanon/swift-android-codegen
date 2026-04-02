import Testing
@testable import BridgeGenCore

@Suite("KotlinBridgeEmitter")
struct KotlinBridgeEmitterTests {
    let config = BridgeGenConfig(
        bridgePackage: "com.example.bridge",
        runtimePackage: "com.example.runtime",
        sourcePackage: "com.example.source"
    )

    @Test("Emits basic bridge with one method")
    func basicBridge() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "TestBridge",
            swiftTypeName: "DefaultTestUseCase",
            initParams: [],
            methods: [
                .init(
                    name: "fetch",
                    params: [],
                    returnType: .init(swiftType: .simple("ProjectOverview"), isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("package com.example.bridge"))
        #expect(output.contains("import com.example.runtime.await"))
        #expect(output.contains("import kotlinx.coroutines.Dispatchers"))
        #expect(output.contains("import kotlinx.coroutines.withContext"))
        #expect(output.contains("import org.swift.swiftkit.core.SwiftArena"))
        #expect(output.contains("import com.example.source.DefaultTestUseCase"))
        #expect(output.contains("import com.example.source.ProjectOverview"))
        #expect(output.contains("class TestBridge {"))
        #expect(output.contains("private val arena = SwiftArena.ofAuto()"))
        #expect(output.contains("private val impl = DefaultTestUseCase.init("))
        #expect(output.contains("suspend fun fetch(): ProjectOverview"))
        #expect(output.contains("withContext(Dispatchers.IO)"))
        #expect(output.contains("impl.fetch(arena)"))
    }

    @Test("Emits Data parameter as ByteArray with fromByteArray conversion")
    func dataParameter() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "UploadBridge",
            swiftTypeName: "DefaultUploadUseCase",
            initParams: [],
            methods: [
                .init(
                    name: "upload",
                    params: [
                        .init(name: "imageData", swiftType: .data),
                    ],
                    returnType: .init(swiftType: .simple("UploadResult"), isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("imageData: ByteArray"))
        #expect(output.contains("Data.fromByteArray(imageData, arena)"))
        #expect(output.contains("import com.example.source.Data"))
    }

    @Test("Emits Data return type with toByteArray conversion")
    func dataReturnType() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "DownloadBridge",
            swiftTypeName: "DefaultDownloadUseCase",
            initParams: [],
            methods: [
                .init(
                    name: "download",
                    params: [.init(name: "id", swiftType: .simple("String"))],
                    returnType: .init(swiftType: .data, isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains(": ByteArray"))
        #expect(output.contains(".toByteArray()"))
        #expect(output.contains("import com.example.source.Data"))
    }

    @Test("Emits array parameter with toTypedArray and return with toList")
    func arrayHandling() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "BatchBridge",
            swiftTypeName: "DefaultBatchUseCase",
            initParams: [],
            methods: [
                .init(
                    name: "process",
                    params: [
                        .init(name: "ids", swiftType: .array(.simple("String"))),
                    ],
                    returnType: .init(swiftType: .array(.simple("Result")), isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("ids: List<String>"))
        #expect(output.contains("ids.toTypedArray()"))
        #expect(output.contains(".toList()"))
    }

    @Test("Emits void return without type annotation")
    func voidReturn() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "ActionBridge",
            swiftTypeName: "DefaultActionUseCase",
            initParams: [],
            methods: [
                .init(
                    name: "execute",
                    params: [.init(name: "id", swiftType: .simple("String"))],
                    returnType: .void
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("suspend fun execute(id: String) ="))
        #expect(!output.contains("suspend fun execute(id: String):"))
    }

    @Test("Emits constructor with multiple init params")
    func multipleInitParams() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "ListBridge",
            swiftTypeName: "DefaultListUseCase",
            initParams: [
                .init(name: "projectClient", swiftType: .simple("ProjectClient")),
                .init(name: "profileClient", swiftType: .simple("ProfileClient")),
            ],
            methods: [
                .init(
                    name: "fetch",
                    params: [],
                    returnType: .init(swiftType: .simple("Overview"), isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("class ListBridge("))
        #expect(output.contains("private val projectClient: ProjectClient,"))
        #expect(output.contains("private val profileClient: ProfileClient,"))
        #expect(output.contains("private val impl = DefaultListUseCase.init("))
        #expect(output.contains("projectClient,"))
        #expect(output.contains("profileClient,"))
        #expect(output.contains("import com.example.source.ProjectClient"))
        #expect(output.contains("import com.example.source.ProfileClient"))
    }

    @Test("Golden file — full output snapshot")
    func goldenFile() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "ProjectListBridge",
            swiftTypeName: "DefaultProjectListUseCase",
            initParams: [
                .init(name: "projectClient", swiftType: .simple("ProjectClient")),
                .init(name: "profileClient", swiftType: .simple("ProfileClient")),
            ],
            methods: [
                .init(
                    name: "fetch",
                    params: [],
                    returnType: .init(swiftType: .simple("ProjectListOverview"), isVoid: false)
                ),
                .init(
                    name: "upload",
                    params: [
                        .init(name: "projectId", swiftType: .simple("String")),
                        .init(name: "imageData", swiftType: .data),
                    ],
                    returnType: .void
                ),
            ]
        )

        let output = emitter.emit(bridge)

        // Golden file: full snapshot of emitter output to catch formatting regressions.
        let expected = """
package com.example.bridge

import com.example.runtime.await
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.swift.swiftkit.core.SwiftArena
import com.example.source.DefaultProjectListUseCase
import com.example.source.ProjectListOverview
import com.example.source.Data
import com.example.source.ProjectClient
import com.example.source.ProfileClient

class ProjectListBridge(
    private val projectClient: ProjectClient,
    private val profileClient: ProfileClient,
) {
    private val arena = SwiftArena.ofAuto()
    private val impl = DefaultProjectListUseCase.init(projectClient, profileClient, arena)
    suspend fun fetch(): ProjectListOverview =
        withContext(Dispatchers.IO) {
            impl.fetch(arena)
                .await()
        }

    suspend fun upload(projectId: String, imageData: ByteArray) =
        withContext(Dispatchers.IO) {
            val swiftImageData = Data.fromByteArray(imageData, arena)
            impl.upload(projectId, swiftImageData)
                .await()
        }
}

"""
        #expect(output == expected)
    }

    @Test("Emits optional types with ? in Kotlin")
    func optionalTypes() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "SearchBridge",
            swiftTypeName: "DefaultSearchUseCase",
            initParams: [],
            methods: [
                .init(
                    name: "search",
                    params: [
                        .init(name: "query", swiftType: .simple("String")),
                        .init(name: "filter", swiftType: .optional(.simple("String"))),
                    ],
                    returnType: .init(swiftType: .optional(.simple("SearchResult")), isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("filter: String?"))
        #expect(output.contains(": SearchResult?"))
    }
}
