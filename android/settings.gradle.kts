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
    // Android modules fail to compile under AGP 9. Pinned to the stable 8.9.1
    // line (Gradle 8.11.1, Kotlin 2.1.0), which supports compileSdk 36 and the
    // whole plugin set.
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
