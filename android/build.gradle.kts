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
// Add the bundled model to that plugin module's compile classpath as well.
subprojects {
    afterEvaluate {
        if (project.name == "google_mlkit_text_recognition") {
            project.dependencies.add(
                "implementation",
                "com.google.mlkit:text-recognition-devanagari:16.0.1"
            )
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
