import ArgumentParser
import BridgeGenCore
import Foundation

@main
struct BridgeGenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bridge-gen",
        abstract: "Generate Kotlin bridge classes from @AndroidBridge-annotated Swift types."
    )

    @Option(help: "Swift source directory to scan.")
    var sourceDir: String

    @Option(help: "Output directory for generated .kt files.")
    var outputDir: String

    @Option(help: "Kotlin package for generated bridges.")
    var bridgePackage: String

    @Option(help: "Kotlin package prefix for swift-java generated types.")
    var sourcePackage: String

    @Option(help: "Runtime package for the await() extension.")
    var runtimePackage: String = "dev.anicanon.swiftandroid.codegen.runtime"

    func run() throws {
        let sourceURL = URL(fileURLWithPath: sourceDir)
        let outputURL = URL(fileURLWithPath: outputDir)

        let analyzer = SwiftSourceAnalyzer()
        let bridges = try analyzer.analyze(directory: sourceURL)

        guard !bridges.isEmpty else {
            print("No @AndroidBridge annotations found in \(sourceDir)")
            return
        }

        let config = BridgeGenConfig(
            bridgePackage: bridgePackage,
            runtimePackage: runtimePackage,
            sourcePackage: sourcePackage
        )

        let emitter = KotlinBridgeEmitter(config: config)

        let bridgeDir = outputURL.appendingPathComponent(
            bridgePackage.replacingOccurrences(of: ".", with: "/")
        )
        try FileManager.default.createDirectory(at: bridgeDir, withIntermediateDirectories: true)

        for bridge in bridges {
            let source = emitter.emit(bridge)
            let file = bridgeDir.appendingPathComponent("\(bridge.bridgeName).kt")
            try source.write(to: file, atomically: true, encoding: .utf8)
        }

        print("Generated \(bridges.count) bridge(s) in \(bridgeDir.path)")
    }
}
