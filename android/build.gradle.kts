allprojects {
    repositories {
        google()
        mavenCentral()
        // Expose the veepoo_sdk local AARs to all subprojects (including :app)
        // so that transitive resolution of :veepoo_sdk's flatDir dependencies works.
        flatDir {
            dirs("${rootProject.projectDir}/../packages/veepoo_sdk/android/libs")
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
