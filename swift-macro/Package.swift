// swift-tools-version: 6.0

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "SwiftAndroidCodegen",
    platforms: [.macOS(.v13), .iOS(.v13)],
    products: [
        .library(
            name: "SwiftAndroidCodegen",
            targets: ["SwiftAndroidCodegen"]
        ),
        .executable(
            name: "bridge-gen",
            targets: ["BridgeGen"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .macro(
            name: "SwiftAndroidCodegenMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "SwiftAndroidCodegen",
            dependencies: ["SwiftAndroidCodegenMacros"]
        ),
        .target(
            name: "BridgeGenCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "BridgeGen",
            dependencies: [
                "BridgeGenCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SwiftAndroidCodegenTests",
            dependencies: [
                "SwiftAndroidCodegenMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "BridgeGenTests",
            dependencies: ["BridgeGenCore"]
        ),
    ]
)
