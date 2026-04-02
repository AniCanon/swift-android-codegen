import Foundation

/// Configuration for bridge generation.
public struct BridgeGenConfig: Sendable {
    public let bridgePackage: String
    public let runtimePackage: String
    public let sourcePackage: String

    public init(
        bridgePackage: String,
        runtimePackage: String,
        sourcePackage: String
    ) {
        self.bridgePackage = bridgePackage
        self.runtimePackage = runtimePackage
        self.sourcePackage = sourcePackage
    }
}

/// Emits Kotlin bridge source files from BridgeDescriptors.
public struct KotlinBridgeEmitter {
    public let config: BridgeGenConfig

    public init(config: BridgeGenConfig) {
        self.config = config
    }

    public func emit(_ bridge: BridgeDescriptor) -> String {
        var w = CodeWriter()

        w.line("package \(config.bridgePackage)")
        w.line()
        for imp in collectImports(bridge) {
            w.line("import \(imp)")
        }
        w.line()

        emitClassHeader(&w, bridge: bridge)
        emitInstanceProperties(&w, bridge: bridge)

        for (i, method) in bridge.methods.enumerated() {
            if i > 0 { w.line() }
            emitMethod(&w, method: method)
        }

        w.line("}")
        return w.output
    }

    // MARK: - Imports

    private func collectImports(_ bridge: BridgeDescriptor) -> [String] {
        var imports = OrderedSet<String>()
        imports.append(config.runtimePackage + ".await")
        imports.append("kotlinx.coroutines.Dispatchers")
        imports.append("kotlinx.coroutines.withContext")
        imports.append("org.swift.swiftkit.core.SwiftArena")
        imports.append(config.sourcePackage + "." + bridge.swiftTypeName)

        for method in bridge.methods {
            if !method.returnType.isVoid {
                if let name = method.returnType.swiftType.importableTypeName {
                    imports.append(config.sourcePackage + "." + name)
                }
                if method.returnType.swiftType.isData {
                    imports.append(config.sourcePackage + ".Data")
                }
            }
            for param in method.params {
                if let name = param.swiftType.importableTypeName {
                    imports.append(config.sourcePackage + "." + name)
                }
                if param.swiftType.isData {
                    imports.append(config.sourcePackage + ".Data")
                }
            }
        }

        for initParam in bridge.initParams {
            if let name = initParam.swiftType.importableTypeName {
                imports.append(config.sourcePackage + "." + name)
            }
        }

        return imports.elements
    }

    // MARK: - Class structure

    private func emitClassHeader(_ w: inout CodeWriter, bridge: BridgeDescriptor) {
        if bridge.initParams.isEmpty {
            w.line("class \(bridge.bridgeName) {")
        } else {
            w.line("class \(bridge.bridgeName)(")
            w.indented { w in
                for initParam in bridge.initParams {
                    w.line("private val \(initParam.name): \(initParam.swiftType.kotlinType),")
                }
            }
            w.line(") {")
        }
    }

    private func emitInstanceProperties(_ w: inout CodeWriter, bridge: BridgeDescriptor) {
        w.indented { w in
            w.line("private val arena = SwiftArena.ofAuto()")

            var initArgs = bridge.initParams.map(\.name)
            initArgs.append("arena")
            let argsString = initArgs.joined(separator: ", ")

            w.line("private val impl = \(bridge.swiftTypeName).init(\(argsString))")
        }
    }

    // MARK: - Methods

    private func emitMethod(_ w: inout CodeWriter, method: BridgeDescriptor.Method) {
        let returnType = method.returnType.swiftType.kotlinType
        let paramDecls = method.params.map { "\($0.name): \($0.swiftType.kotlinType)" }

        let paramsString = paramDecls.count > 2
            ? "\n        " + paramDecls.joined(separator: ",\n        ") + ",\n    "
            : paramDecls.joined(separator: ", ")

        let returnAnnotation = method.returnType.isVoid ? "" : ": \(returnType)"

        w.indented { w in
            w.line("suspend fun \(method.name)(\(paramsString))\(returnAnnotation) =")
            w.indented { w in
                w.line("withContext(Dispatchers.IO) {")
                w.indented { w in
                    for param in method.params where param.swiftType.isData {
                        w.line("val swift\(param.name.uppercasedFirst) = Data.fromByteArray(\(param.name), arena)")
                    }
                    emitMethodCall(&w, method: method)
                }
                w.line("}")
            }
        }
    }

    private func emitMethodCall(_ w: inout CodeWriter, method: BridgeDescriptor.Method) {
        var args: [String] = method.params.map { param in
            if param.swiftType.isData {
                return "swift\(param.name.uppercasedFirst)"
            } else if param.swiftType.isArray {
                return "\(param.name).toTypedArray()"
            } else {
                return param.name
            }
        }
        if !method.returnType.isVoid {
            args.append("arena")
        }

        var chain = "impl.\(method.name)(\(args.joined(separator: ", ")))"
        chain += "\n" + String(repeating: "    ", count: 4) + ".await()"

        if method.returnType.swiftType.isData {
            chain += "\n" + String(repeating: "    ", count: 4) + ".toByteArray()"
        } else if method.returnType.swiftType.isArray {
            chain += "\n" + String(repeating: "    ", count: 4) + ".toList()"
        }

        w.line(chain)
    }
}

// MARK: - OrderedSet (minimal)

struct OrderedSet<Element: Hashable> {
    private var set: Set<Element> = []
    private(set) var elements: [Element] = []

    mutating func append(_ element: Element) {
        if set.insert(element).inserted {
            elements.append(element)
        }
    }
}

private extension String {
    var uppercasedFirst: String {
        guard let first = self.first else { return self }
        return first.uppercased() + dropFirst()
    }
}
