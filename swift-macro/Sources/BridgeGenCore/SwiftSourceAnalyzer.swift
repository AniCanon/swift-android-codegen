import Foundation
import SwiftParser
import SwiftSyntax

/// Analyzes Swift source files using swift-syntax to extract bridge metadata.
public struct SwiftSourceAnalyzer {

    public init() {}

    /// Analyze all .swift files in a directory tree.
    public func analyze(directory: URL) throws -> [BridgeDescriptor] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        var results: [BridgeDescriptor] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            results.append(contentsOf: analyzeSource(source))
        }
        return results.sorted { $0.bridgeName < $1.bridgeName }
    }

    /// Analyze a single Swift source string.
    public func analyzeSource(_ source: String) -> [BridgeDescriptor] {
        let sourceFile = Parser.parse(source: source)
        let visitor = BridgeVisitor(viewMode: .sourceAccurate)
        visitor.walk(sourceFile)
        return visitor.bridges
    }
}

// MARK: - AST Visitor

private final class BridgeVisitor: SyntaxVisitor {
    var bridges: [BridgeDescriptor] = []

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if let bridge = extractBridge(from: node.attributes, name: node.name, members: node.memberBlock) {
            bridges.append(bridge)
        }
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if let bridge = extractBridge(from: node.attributes, name: node.name, members: node.memberBlock) {
            bridges.append(bridge)
        }
        return .skipChildren
    }

    private func extractBridge(
        from attributes: AttributeListSyntax,
        name: TokenSyntax,
        members: MemberBlockSyntax
    ) -> BridgeDescriptor? {
        guard let bridgeName = extractBridgeName(from: attributes) else { return nil }

        let initParams = extractInitParams(from: members)
        let methods = extractMethods(from: members)

        guard !methods.isEmpty else {
            print("warning: @AndroidBridge(\"\(bridgeName)\") on '\(name.text)' has no public async methods — skipping")
            return nil
        }

        return BridgeDescriptor(
            bridgeName: bridgeName,
            swiftTypeName: name.text,
            initParams: initParams,
            methods: methods
        )
    }

    private func extractBridgeName(from attributes: AttributeListSyntax) -> String? {
        for element in attributes {
            guard case .attribute(let attr) = element,
                  attr.attributeName.trimmedDescription == "AndroidBridge",
                  let args = attr.arguments,
                  case .argumentList(let argList) = args,
                  let firstArg = argList.first,
                  let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self),
                  let segment = stringLiteral.segments.first,
                  case .stringSegment(let text) = segment
            else { continue }
            return text.content.text
        }
        return nil
    }

    private func extractInitParams(from members: MemberBlockSyntax) -> [BridgeDescriptor.InitParam] {
        // Uses the first public init found (the designated initializer).
        for member in members.members {
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { continue }
            let isPublic = initDecl.modifiers.contains { $0.name.text == "public" }
            guard isPublic else { continue }

            var params: [BridgeDescriptor.InitParam] = []
            for param in initDecl.signature.parameterClause.parameters {
                let paramName = (param.secondName ?? param.firstName).text
                let swiftType = parseSwiftType(param.type)
                params.append(.init(name: paramName, swiftType: swiftType))
            }
            return params
        }
        return []
    }

    private func extractMethods(from members: MemberBlockSyntax) -> [BridgeDescriptor.Method] {
        var methods: [BridgeDescriptor.Method] = []

        for member in members.members {
            guard let funcDecl = member.decl.as(FunctionDeclSyntax.self) else { continue }

            let isPublic = funcDecl.modifiers.contains { $0.name.text == "public" }
            guard isPublic else { continue }

            let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
            guard isAsync else { continue }

            let methodName = funcDecl.name.text
            let params = extractMethodParams(from: funcDecl.signature.parameterClause)
            let returnType = extractReturnType(from: funcDecl.signature.returnClause)

            methods.append(.init(name: methodName, params: params, returnType: returnType))
        }

        return methods
    }

    private func extractMethodParams(from clause: FunctionParameterClauseSyntax) -> [BridgeDescriptor.Param] {
        clause.parameters.map { param in
            let name = (param.secondName ?? param.firstName).text
            let swiftType = parseSwiftType(param.type)
            return .init(name: name, swiftType: swiftType)
        }
    }

    private func extractReturnType(from returnClause: ReturnClauseSyntax?) -> BridgeDescriptor.ReturnType {
        guard let returnClause else { return .void }
        let swiftType = parseSwiftType(returnClause.type)
        let isVoid = swiftType.kotlinType == "Void" || swiftType.kotlinType == "Unit"
        return .init(swiftType: swiftType, isVoid: isVoid)
    }

    private func parseSwiftType(_ type: TypeSyntax) -> SwiftType {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return .optional(parseSwiftType(optional.wrappedType))
        }

        if let array = type.as(ArrayTypeSyntax.self) {
            return .array(parseSwiftType(array.element))
        }

        if let identifierType = type.as(IdentifierTypeSyntax.self) {
            let name = identifierType.name.text

            if name == "Optional",
               let genericArgs = identifierType.genericArgumentClause,
               let firstArg = genericArgs.arguments.first,
               case .type(let innerType) = firstArg.argument {
                return .optional(parseSwiftType(innerType))
            }

            if name == "Array",
               let genericArgs = identifierType.genericArgumentClause,
               let firstArg = genericArgs.arguments.first,
               case .type(let elementType) = firstArg.argument {
                return .array(parseSwiftType(elementType))
            }

            if name == "Data" {
                return .data
            }

            return .simple(name)
        }

        if let memberType = type.as(MemberTypeSyntax.self) {
            let base = memberType.baseType.trimmedDescription
            let name = memberType.name.text
            return .member(base: base, name: name)
        }

        if let someOrAny = type.as(SomeOrAnyTypeSyntax.self) {
            return parseSwiftType(someOrAny.constraint)
        }

        return .simple(type.trimmedDescription)
    }
}
