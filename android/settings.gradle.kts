pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 9 only reads the new DSL, which the current plugin set (file_picker
    // 11.0.2 et al., still on the old Gradle-plugin DSL) does not use — their
    // Android modules fail to compile under AGP 9. So this stays on the 8.x
    // line, which supports compileSdk 36 and the whole plugin set.
    //
    // CHANGE #225: moved 8.9.1 -> 8.11.1 because Flutter 3.47.0 refuses to build
    // below AGP 8.11.1. Still 8.x, so the AGP 9 / new-DSL problem above does not
    // apply. AGP 8.11 needs Gradle >= 8.13; the wrapper is on 8.14.3.
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
