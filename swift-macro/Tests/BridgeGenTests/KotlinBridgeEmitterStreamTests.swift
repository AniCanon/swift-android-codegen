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
        #expect(!output.contains("import kotlinx.coroutines.flow.flow"))
        #expect(!output.contains("import kotlinx.coroutines.flow.emitAll"))
        #expect(output.contains("import com.example.runtime.observationFlow"))
        #expect(output.contains("import com.example.source.HomeUseCaseObserveObservation"))
        #expect(output.contains("import com.example.source.HomeOverview"))
        #expect(output.contains("""
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
