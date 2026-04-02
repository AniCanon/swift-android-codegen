import SwiftSyntax
import SwiftSyntaxMacros

/// A peer macro that serves as a marker annotation.
///
/// It produces no additional code — its purpose is to be scannable
/// by the Gradle plugin which reads Swift source files to discover
/// which types should have Kotlin bridges generated.
public struct AndroidBridgeMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
