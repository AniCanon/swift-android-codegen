package dev.anicanon.swiftandroid.codegen.gradle;

import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class SwiftAndroidCodegenPlugin implements Plugin<Project> {
    @Override
    public void apply(Project project) {
        SwiftAndroidCodegenExtension extension = project.getExtensions().create(
                "swiftAndroidCodegen",
                SwiftAndroidCodegenExtension.class,
                project.getObjects()
        );

        project.getTasks().register(
                "generateSwiftAndroidBridges",
                GenerateSwiftAndroidBridgesTask.class,
                task -> {
                    task.getBridgeGenDir().set(extension.getBridgeGenDir());
                    task.getSwiftSourceDir().set(extension.getSwiftSourceDir());
                    task.getOutputDir().set(extension.getOutputDir());
                    task.getBridgePackage().set(extension.getBridgePackage());
                    task.getSourcePackage().set(extension.getSourcePackage());
                    task.getRuntimePackage().set(extension.getRuntimePackage());
                }
        );
    }
}
