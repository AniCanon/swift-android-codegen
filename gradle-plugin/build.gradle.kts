plugins {
    `java-gradle-plugin`
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
    withSourcesJar()
    withJavadocJar()
}

gradlePlugin {
    plugins {
        create("swiftAndroidCodegen") {
            id = "dev.anicanon.swift-android-codegen"
            implementationClass = "dev.anicanon.swiftandroid.codegen.gradle.SwiftAndroidCodegenPlugin"
            displayName = "swift-android-codegen"
            description = "Generates Kotlin bridge classes from @AndroidBridge-annotated Swift types."
        }
    }
}
