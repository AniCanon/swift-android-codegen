package dev.anicanon.swiftandroid.codegen.gradle;

import org.gradle.api.file.DirectoryProperty;
import org.gradle.api.model.ObjectFactory;
import org.gradle.api.provider.Property;

public abstract class SwiftAndroidCodegenExtension {

    /** Directory containing the bridge-gen Swift package (with Package.swift). */
    public abstract DirectoryProperty getBridgeGenDir();

    /** Directory containing Swift source files with @AndroidBridge annotations. */
    public abstract DirectoryProperty getSwiftSourceDir();

    /** Directory where generated Kotlin bridge files will be written. */
    public abstract DirectoryProperty getOutputDir();

    /** Package name for the generated Kotlin bridge classes. */
    public abstract Property<String> getBridgePackage();

    /** Kotlin package for swift-java generated types (used in imports). */
    public abstract Property<String> getSourcePackage();

    /** Runtime package for the await() extension. */
    public abstract Property<String> getRuntimePackage();

    public SwiftAndroidCodegenExtension(ObjectFactory objects) {
        getRuntimePackage().convention("dev.anicanon.swiftandroid.codegen.runtime");
    }
}
