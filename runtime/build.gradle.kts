plugins {
    kotlin("jvm") version "2.1.20"
    `java-library`
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
    withSourcesJar()
    withJavadocJar()
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

repositories {
    mavenLocal()
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.1")
    // Pinned vendored build of Apple swift-java's swiftkit (see repositories
    // block in the root build) — replaces the per-developer 1.0-SNAPSHOT
    // publishToMavenLocal bootstrap so fresh clones and CI resolve it.
    compileOnly("org.swift.swiftkit:swiftkit-core:1.0-0bdba49")
}
