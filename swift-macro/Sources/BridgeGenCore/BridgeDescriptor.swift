/// Describes a single Kotlin bridge to generate.
public struct BridgeDescriptor: Sendable {
    public let bridgeName: String
    public let swiftTypeName: String
    public let initParams: [InitParam]
    public let methods: [Method]

    public init(bridgeName: String, swiftTypeName: String, initParams: [InitParam], methods: [Method]) {
        self.bridgeName = bridgeName
        self.swiftTypeName = swiftTypeName
        self.initParams = initParams
        self.methods = methods
    }

    public struct InitParam: Sendable {
        public let name: String
        public let swiftType: SwiftType

        public init(name: String, swiftType: SwiftType) {
            self.name = name
            self.swiftType = swiftType
        }
    }

    public struct Method: Sendable {
        public let name: String
        public let params: [Param]
        public let returnType: ReturnType

        public init(name: String, params: [Param], returnType: ReturnType) {
            self.name = name
            self.params = params
            self.returnType = returnType
        }
    }

    public struct Param: Sendable {
        public let name: String
        public let swiftType: SwiftType

        public init(name: String, swiftType: SwiftType) {
            self.name = name
            self.swiftType = swiftType
        }
    }

    public struct ReturnType: Sendable {
        public let swiftType: SwiftType
        public let isVoid: Bool

        public init(swiftType: SwiftType, isVoid: Bool) {
            self.swiftType = swiftType
            self.isVoid = isVoid
        }

        nonisolated public static let void = ReturnType(swiftType: .simple("Void"), isVoid: true)
    }
}

/// A parsed Swift type reference, carrying enough info for Kotlin mapping.
public indirect enum SwiftType: Sendable {
    case simple(String)
    case member(base: String, name: String)
    case optional(SwiftType)
    case array(SwiftType)
    case data

    public var isData: Bool {
        if case .data = self { return true }
        return false
    }

    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    public var kotlinType: String {
        switch self {
        case .simple(let name): mapPrimitive(name)
        case .member(let base, let name): "\(base).\(name)"
        case .optional(let inner): "\(inner.kotlinType)?"
        case .array(let element): "List<\(element.kotlinType)>"
        case .data: "ByteArray"
        }
    }

    public var importableTypeName: String? {
        switch self {
        case .simple(let name):
            Self.primitiveTypes.contains(name) ? nil : name
        case .member(let base, _):
            base
        case .optional(let inner):
            inner.importableTypeName
        case .array(let element):
            element.importableTypeName
        case .data:
            nil
        }
    }

    static let primitiveTypes: Set<String> = [
        "String", "Int", "Long", "Double", "Float", "Bool", "Boolean", "Void",
    ]

    private func mapPrimitive(_ name: String) -> String {
        switch name {
        case "Bool": "Boolean"
        case "Int": "Long"
        default: name
        }
    }
}
