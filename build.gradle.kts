group = "dev.anicanon.swiftandroid.codegen"
version = "0.1.0-SNAPSHOT"

allprojects {
    repositories {
        mavenCentral()
        google()
        gradlePluginPortal()
    }
}

subprojects {
    apply(plugin = "maven-publish")

    afterEvaluate {
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
