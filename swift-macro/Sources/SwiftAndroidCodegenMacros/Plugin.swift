import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiftAndroidCodegenPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        AndroidBridgeMacro.self,
    ]
}
