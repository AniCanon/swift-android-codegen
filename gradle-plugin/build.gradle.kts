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
        // Publish the plugin (and its marker) to GitHub Packages so a fresh
        // consumer clone resolves it remotely, not from a local bootstrap.
        // Same env/gpr credential resolution as the root runtime publication;
        // no-op without credentials so a plain local build never fails.
        val ownerAndRepo = System.getenv("GITHUB_REPOSITORY") ?: "AniCanon/swift-android-codegen"
        val user = findProperty("gpr.user") as String? ?: System.getenv("GITHUB_ACTOR")
        val token = findProperty("gpr.key") as String? ?: System.getenv("GITHUB_TOKEN")
        if (user != null && token != null) {
            repositories {
                maven {
                    name = "GitHubPackages"
                    url = uri("https://maven.pkg.github.com/$ownerAndRepo")
                    credentials {
                        username = user
                        password = token
                    }
                }
            }
        }
    }
}
