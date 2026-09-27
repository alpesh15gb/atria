allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Several plugins (e.g. file_picker) still compile against android-34 while
// their own dependencies (flutter_plugin_android_lifecycle) require compileSdk
// 36, which fails checkAarMetadata inside those modules. Force every plugin
// module up to 36; :app already sets compileSdk = 36 explicitly.
// Several plugins (e.g. file_picker) still compile against android-34 while
// their own dependencies (flutter_plugin_android_lifecycle) require compileSdk
// 36, which fails checkAarMetadata inside those modules. Force every plugin
// module up to 36 *after* it is evaluated so its own android{} block cannot
// override it; :app sets compileSdk = 36 itself.
subprojects {
    if (!project.state.executed) {
        afterEvaluate {
            extensions.findByName("android")?.let { ext ->
                (ext as com.android.build.gradle.LibraryExtension).compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
