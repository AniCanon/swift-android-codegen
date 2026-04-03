group = "dev.anicanon.swiftandroid.codegen"
version = "0.2.0"

allprojects {
    group = rootProject.group
    version = rootProject.version
    repositories {
        mavenCentral()
        google()
        gradlePluginPortal()
    }
}

subprojects {
    afterEvaluate {
        // gradle-plugin subproject manages its own publishing via java-gradle-plugin
        if (!plugins.hasPlugin("java-gradle-plugin")) {
            apply(plugin = "maven-publish")
            extensions.findByType<PublishingExtension>()?.apply {
                publications {
                    create<MavenPublication>("maven") {
                        from(components.findByName("java") ?: return@create)
                        groupId = rootProject.group.toString()
                        version = rootProject.version.toString()
                    }
                }
            }
        }
    }
}
