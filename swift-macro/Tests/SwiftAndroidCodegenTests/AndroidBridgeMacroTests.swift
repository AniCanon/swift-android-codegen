import Testing
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport

#if canImport(SwiftAndroidCodegenMacros)
import SwiftAndroidCodegenMacros

@Suite("AndroidBridge Macro")
struct AndroidBridgeMacroTests {
    let macros: [String: Macro.Type] = [
        "AndroidBridge": AndroidBridgeMacro.self,
    ]

    @Test("Macro produces no peers")
    func macroProducesNoPeers() {
        assertMacroExpansion(
            """
            @AndroidBridge("ProjectListBridge")
            public struct DefaultProjectListUseCase {
            }
            """,
            expandedSource: """
            public struct DefaultProjectListUseCase {
            }
            """,
            macros: macros
        )
    }

    @Test("Macro with custom name")
    func macroWithCustomName() {
        assertMacroExpansion(
            """
            @AndroidBridge("CharacterDetailBridge")
            public struct DefaultCharacterDetailOverviewUseCase {
            }
            """,
            expandedSource: """
            public struct DefaultCharacterDetailOverviewUseCase {
            }
            """,
            macros: macros
        )
    }
}
#endif
