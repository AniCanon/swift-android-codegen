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

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if let bridge = extractBridge(from: node.attributes, name: node.name, members: node.memberBlock, requiresPublic: false, isProtocol: true) {
            bridges.append(bridge)
        }
        return .skipChildren
    }

    private func extractBridge(
        from attributes: AttributeListSyntax,
        name: TokenSyntax,
        members: MemberBlockSyntax,
        requiresPublic: Bool = true,
        isProtocol: Bool = false
    ) -> BridgeDescriptor? {
        guard let bridgeName = extractBridgeName(from: attributes) else { return nil }

        let methods = extractMethods(from: members, requiresPublic: requiresPublic, isProtocol: isProtocol, typeName: name.text)
        guard !methods.isEmpty else {
            print("warning: @AndroidBridge(\"\(bridgeName)\") on '\(name.text)' has no public async or stream methods — skipping")
            return nil
        }

        return BridgeDescriptor(
            bridgeName: bridgeName,
            swiftTypeName: name.text,
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

    private func extractMethods(
        from members: MemberBlockSyntax,
        requiresPublic: Bool,
        isProtocol: Bool,
        typeName: String
    ) -> [BridgeDescriptor.Method] {
        var methods: [BridgeDescriptor.Method] = []
        var streamMethodNames: Set<String> = []

        for member in members.members {
            guard let funcDecl = member.decl.as(FunctionDeclSyntax.self) else { continue }

            let isPublic = funcDecl.modifiers.contains { $0.name.text == "public" }
            guard isPublic || !requiresPublic else { continue }

            let methodName = funcDecl.name.text
            let params = extractMethodParams(from: funcDecl.signature.parameterClause)
            let effects = funcDecl.signature.effectSpecifiers

            if effects?.asyncSpecifier != nil {
                let returnType = extractReturnType(from: funcDecl.signature.returnClause)
                methods.append(.init(name: methodName, params: params, returnType: returnType))
                continue
            }

            guard isStreamReturning(funcDecl.signature.returnClause) else { continue }

            guard isProtocol else {
                print("warning: '\(methodName)' on '\(typeName)' streams values, which is only bridged on protocols — skipping")
                continue
            }

            guard effects?.throwsClause == nil,
                  let stream = extractStream(from: funcDecl.signature.returnClause)
            else {
                print("warning: '\(methodName)' on '\(typeName)' streams values in an unsupported shape — skipping")
                continue
            }

            guard stream.element.isBridgeableStreamElement else {
                print("warning: '\(methodName)' streams '\(stream.element.swiftSpelling)', which cannot be bridged — skipping")
                continue
            }

            guard streamMethodNames.insert(methodName).inserted else {
                print("warning: '\(methodName)' on '\(typeName)' overloads an existing stream method — skipping")
                continue
            }

            methods.append(.init(
                name: methodName,
                params: params,
                returnType: .init(swiftType: stream.element, isVoid: false),
                kind: .stream(throwing: stream.throwing)
            ))
        }

        return methods
    }

    /// Whether `returnClause` names `AsyncStream`/`AsyncThrowingStream`, regardless of generic arity
    /// or throwing shape — used to distinguish "not a stream at all" from "an unsupported stream shape".
    private func isStreamReturning(_ returnClause: ReturnClauseSyntax?) -> Bool {
        guard let identifier = returnClause?.type.as(IdentifierTypeSyntax.self) else { return false }
        return identifier.name.text == "AsyncStream" || identifier.name.text == "AsyncThrowingStream"
    }

    private func extractMethodParams(from clause: FunctionParameterClauseSyntax) -> [BridgeDescriptor.Param] {
        clause.parameters.map { param in
            let name = (param.secondName ?? param.firstName).text
            let label = param.firstName.text == "_" ? nil : param.firstName.text
            return .init(name: name, swiftType: parseSwiftType(param.type), label: label)
        }
    }

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
            guard failure == "Error" || failure == "any Error" || failure == "Swift.Error" else { return nil }
            return (parseSwiftType(types[0]), true)
        default:
            return nil
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
