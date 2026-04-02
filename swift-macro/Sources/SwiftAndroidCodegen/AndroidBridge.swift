/// Marks a swift-java exported type for Kotlin bridge generation.
///
/// The Gradle plugin scans Swift source files for this annotation
/// and generates a corresponding Kotlin bridge class.
///
/// Usage:
/// ```swift
/// @AndroidBridge("ProjectListBridge")
/// public struct DefaultProjectListUseCase: ProjectListUseCase {
///     ...
/// }
/// ```
@attached(peer)
public macro AndroidBridge(_ name: String) = #externalMacro(
    module: "SwiftAndroidCodegenMacros",
    type: "AndroidBridgeMacro"
)
