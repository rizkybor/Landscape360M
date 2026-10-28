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
// mapbox_maps_flutter_mobile leaves out the Kotlin plugin on AGP 9, expecting Kotlin built
// into AGP, which this project switches off (android.builtInKotlin=false, Flutter template).
// Apply it as soon as the module becomes an Android library, before its kotlin { } block.
subprojects {
    if (name == "mapbox_maps_flutter_mobile") {
        pluginManager.withPlugin("com.android.library") {
            pluginManager.apply("org.jetbrains.kotlin.android")
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
