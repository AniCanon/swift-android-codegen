group = "dev.anicanon.swiftandroid.codegen"
version = "0.2.2"

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
                configureGitHubPackages(this@subprojects)
            }
        }
    }
}

/// Adds the GitHub Packages repository as a publish target so a fresh
/// consumer clone can resolve these artifacts remotely instead of relying
/// on a local `publishToMavenLocal` bootstrap. Owner/repo resolve from the
/// CI `GITHUB_REPOSITORY` env var, falling back to this repo's coordinates;
/// credentials from `gpr.user`/`gpr.key` (local) or `GITHUB_ACTOR`/
/// `GITHUB_TOKEN` (Actions). No-op when no credentials are present, so a
/// plain local build never fails for lack of a token.
fun PublishingExtension.configureGitHubPackages(project: org.gradle.api.Project) {
    val ownerAndRepo = (System.getenv("GITHUB_REPOSITORY") ?: "AniCanon/swift-android-codegen")
    val user = project.findProperty("gpr.user") as String? ?: System.getenv("GITHUB_ACTOR")
    val token = project.findProperty("gpr.key") as String? ?: System.getenv("GITHUB_TOKEN")
    if (user == null || token == null) return
    repositories {
        maven {
            name = "GitHubPackages"
            url = project.uri("https://maven.pkg.github.com/$ownerAndRepo")
            credentials {
                username = user
                password = token
            }
        }
    }
}
