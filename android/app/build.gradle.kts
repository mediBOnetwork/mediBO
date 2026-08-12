import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config is read from android/key.properties (gitignored).
// When that file is absent (e.g. a fresh checkout with no keystore), the release
// build falls back to the debug keys so `flutter run --release` still works — but
// the published APK is always built on this VM where key.properties is present.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "in.medibo.app"
    compileSdk = 36
    // No plugin in this project ships native C/C++ (path_provider_android is
    // pinned below its jni-using 2.3.x), so no NDK is required. Leaving
    // `ndkVersion = flutter.ndkVersion` set makes AGP try to install a ~3GB NDK
    // on this disk-constrained host and fail. Omitted deliberately.

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    defaultConfig {
        applicationId = "in.medibo.app"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = 17
        versionName = "1.3.4"
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // NOTE: on a missing keystore this still assigns debug so the project
            // configures cleanly, but the gradle.taskGraph guard below HARD-FAILS
            // any *Release assemble/bundle before it can produce a debug-signed
            // release artifact (see the 1.1.0 signature-mismatch incident).
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

// FAIL LOUDLY — never silently debug-sign a RELEASE artifact. The 1.1.0 APK
// shipped debug-signed because android/key.properties was absent at build time and
// the release buildType fell back to the debug keys, producing a signature
// mismatch users could not install over the release-signed 1.0.0. This guard fires
// only when a *Release assemble/bundle/package task is actually in the graph, so
// debug builds and `flutter run` are unaffected. Set ALLOW_DEBUG_SIGNING=1 for a
// deliberate local dev release build without the keystore.
gradle.taskGraph.whenReady {
    val buildingRelease = allTasks.any { t ->
        t.name.contains("Release") &&
            (t.name.startsWith("assemble") || t.name.startsWith("bundle") ||
                t.name.startsWith("package"))
    }
    if (buildingRelease && !hasReleaseKeystore &&
        System.getenv("ALLOW_DEBUG_SIGNING") != "1") {
        throw GradleException(
            "\n❌  RELEASE BUILD REFUSED: android/key.properties is missing.\n" +
                "    Refusing to debug-sign a release artifact (this shipped a\n" +
                "    debug-signed medibo-1.1.0.apk with a signature mismatch).\n" +
                "    Restore android/key.properties and retry, or set\n" +
                "    ALLOW_DEBUG_SIGNING=1 for a deliberate local dev release build.\n")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
