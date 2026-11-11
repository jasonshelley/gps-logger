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
// maplibre_gl declares Java/Kotlin 21, but this build uses JDK 17 (Temurin 17
// in C:\src\tools\jdk17). Its code doesn't use anything newer than Java 17, so
// compile every plugin for 17. Remove this if the JDK moves to 21.
subprojects {
    val useJava17: Project.() -> Unit = {
        extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)?.compileOptions {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
        tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    if (state.executed) useJava17() else afterEvaluate { useJava17() }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
