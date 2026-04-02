package dev.anicanon.swiftandroid.codegen.gradle;

import javax.inject.Inject;
import org.gradle.api.DefaultTask;
import org.gradle.api.file.DirectoryProperty;
import org.gradle.api.provider.Property;
import org.gradle.api.tasks.Input;
import org.gradle.api.tasks.InputDirectory;
import org.gradle.api.tasks.Internal;
import org.gradle.api.tasks.Optional;
import org.gradle.api.tasks.OutputDirectory;
import org.gradle.api.tasks.TaskAction;
import org.gradle.process.ExecOperations;

public abstract class GenerateSwiftAndroidBridgesTask extends DefaultTask {

    @Inject
    protected abstract ExecOperations getExecOperations();

    @Internal
    public abstract DirectoryProperty getBridgeGenDir();

    @InputDirectory
    public abstract DirectoryProperty getSwiftSourceDir();

    @OutputDirectory
    public abstract DirectoryProperty getOutputDir();

    @Input
    public abstract Property<String> getBridgePackage();

    @Input
    public abstract Property<String> getSourcePackage();

    @Optional @Input
    public abstract Property<String> getRuntimePackage();

    @TaskAction
    public void generate() {
        var args = new java.util.ArrayList<String>();
        args.add("swift");
        args.add("run");
        args.add("bridge-gen");
        args.add("--source-dir");
        args.add(getSwiftSourceDir().get().getAsFile().getAbsolutePath());
        args.add("--output-dir");
        args.add(getOutputDir().get().getAsFile().getAbsolutePath());
        args.add("--bridge-package");
        args.add(getBridgePackage().get());
        args.add("--source-package");
        args.add(getSourcePackage().get());

        if (getRuntimePackage().isPresent()) {
            args.add("--runtime-package");
            args.add(getRuntimePackage().get());
        }

        getExecOperations().exec(spec -> {
            spec.setWorkingDir(getBridgeGenDir().get().getAsFile());
            spec.commandLine(args);
        });
    }
}
