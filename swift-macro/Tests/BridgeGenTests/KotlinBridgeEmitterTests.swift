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
        #expect(output.contains("import org.swift.swiftkit.core.SwiftMemoryManagement"))
        #expect(output.contains("import com.example.source.DefaultTestUseCase"))
        #expect(output.contains("import com.example.source.ProjectOverview"))
        #expect(output.contains("class TestBridge(\n    private val defaultTestUseCase: DefaultTestUseCase,\n) {"))
        #expect(output.contains("private val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA"))
        #expect(!output.contains(".init("))
        #expect(output.contains("suspend fun fetch(): ProjectOverview"))
        #expect(output.contains("withContext(Dispatchers.IO)"))
        #expect(output.contains("defaultTestUseCase.fetch(arena)"))
    }

    @Test("Emits Data parameter as ByteArray with fromByteArray conversion")
    func dataParameter() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "UploadBridge",
            swiftTypeName: "DefaultUploadUseCase",
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

    @Test("Emits optional return type with orElse(null) conversion")
    func optionalReturnType() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "LatestBridge",
            swiftTypeName: "DefaultLatestUseCase",
            methods: [
                .init(
                    name: "latest",
                    params: [.init(name: "id", swiftType: .simple("String"))],
                    returnType: .init(swiftType: .optional(.simple("Session")), isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains(": Session?"))
        #expect(output.contains(".orElse(null)"))
        #expect(output.contains("import com.example.source.Session"))
    }

    @Test("Emits void return without type annotation")
    func voidReturn() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "ActionBridge",
            swiftTypeName: "DefaultActionUseCase",
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

    @Test("Golden file — full output snapshot")
    func goldenFile() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "ProjectListBridge",
            swiftTypeName: "ProjectListUseCase",
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
import org.swift.swiftkit.core.SwiftMemoryManagement
import com.example.source.ProjectListUseCase
import com.example.source.ProjectListOverview
import com.example.source.Data

class ProjectListBridge(
    private val projectListUseCase: ProjectListUseCase,
) {
    private val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA

    suspend fun fetch(): ProjectListOverview =
        withContext(Dispatchers.IO) {
            projectListUseCase.fetch(arena)
                .await()
        }

    suspend fun upload(projectId: String, imageData: ByteArray) =
        withContext(Dispatchers.IO) {
            projectListUseCase.upload(projectId, Data.fromByteArray(imageData, arena))
                .await()
        }
}

"""
        #expect(output == expected)
    }

    @Test("Omits arena for String array returns (no arena accessor overload exists)")
    func stringArrayReturnHasNoArena() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "RefsBridge",
            swiftTypeName: "DefaultRefsUseCase",
            methods: [
                .init(
                    name: "listReferenceImages",
                    params: [.init(name: "outfitId", swiftType: .simple("String"))],
                    returnType: .init(swiftType: .array(.simple("String")), isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("defaultRefsUseCase.listReferenceImages(outfitId)"))
        #expect(!output.contains("defaultRefsUseCase.listReferenceImages(outfitId, arena)"))
        #expect(output.contains(".toList()"))
    }

    @Test("Omits arena for scalar String return")
    func stringReturnHasNoArena() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "NameBridge",
            swiftTypeName: "DefaultNameUseCase",
            methods: [
                .init(
                    name: "name",
                    params: [.init(name: "id", swiftType: .simple("String"))],
                    returnType: .init(swiftType: .simple("String"), isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("defaultNameUseCase.name(id)"))
        #expect(!output.contains("defaultNameUseCase.name(id, arena)"))
    }

    @Test("Keeps arena for object array returns")
    func objectArrayReturnKeepsArena() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "OutfitsBridge",
            swiftTypeName: "DefaultOutfitsUseCase",
            methods: [
                .init(
                    name: "listOutfits",
                    params: [.init(name: "characterId", swiftType: .simple("String"))],
                    returnType: .init(swiftType: .array(.simple("Outfit")), isVoid: false)
                ),
            ]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("defaultOutfitsUseCase.listOutfits(characterId, arena)"))
    }

    @Test("Emits optional types with ? in Kotlin")
    func optionalTypes() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "SearchBridge",
            swiftTypeName: "DefaultSearchUseCase",
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

    @Test("Bridge wraps the instance it is given")
    func protocolBridge() {
        let emitter = KotlinBridgeEmitter(config: config)
        let bridge = BridgeDescriptor(
            bridgeName: "ProjectListBridge",
            swiftTypeName: "ProjectListUseCase",
            methods: [.init(name: "fetch", params: [], returnType: .init(swiftType: .simple("ProjectListOverview"), isVoid: false))]
        )

        let output = emitter.emit(bridge)

        #expect(output.contains("class ProjectListBridge("))
        #expect(output.contains("private val projectListUseCase: ProjectListUseCase,"))
        #expect(!output.contains("impl"))
        #expect(!output.contains("ProjectListUseCase.init("))
        #expect(output.contains("projectListUseCase.fetch(arena)"))
    }
}
