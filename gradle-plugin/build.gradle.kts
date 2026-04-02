plugins {
    `java-gradle-plugin`
    `maven-publish`
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

// java-gradle-plugin auto-creates "pluginMaven" and marker publications.
// Configure the auto-created publication with the correct coordinates.
afterEvaluate {
    publishing {
        publications {
            named<MavenPublication>("pluginMaven") {
                groupId = rootProject.group.toString()
                artifactId = "codegen-gradle-plugin"
                version = rootProject.version.toString()
            }
        }
    }
}
