allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// google_mlkit_text_recognition 0.15.0 references the Devanagari options in its
// Android source, but its own module does not inherit app-level dependencies.
// Add the bundled model when the plugin's Android library configuration exists.
// Avoid afterEvaluate: evaluationDependsOn(":app") above can evaluate projects first.
subprojects {
    if (name == "google_mlkit_text_recognition") {
        pluginManager.withPlugin("com.android.library") {
            dependencies.add(
                "implementation",
                "com.google.mlkit:text-recognition-devanagari:16.0.1"
            )
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
