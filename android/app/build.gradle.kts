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
        versionCode = 36
        versionName = "1.3.22"
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // rootProject = android/, so a bare basename in key.properties
                // resolves to android/<file>.jks. Plain file() here resolved against
                // android/app/ and broke a restored keystore (CHANGE #276). An
                // absolute path still works — rootProject.file() returns it as-is.
                storeFile = keystoreProperties["storeFile"]?.let { rootProject.file(it) }
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

dependencies {
    // CHANGE #225 — DocScanReadiness needs these symbols in the app module.
    // play-services-base carries GoogleApiAvailability + the ModuleInstall API;
    // the document-scanner artifact is already on the classpath transitively via
    // google_mlkit_document_scanner, and is declared here only so the app module
    // compiles against GmsDocumentScanning directly.
    implementation("com.google.android.gms:play-services-base:18.5.0")
    implementation("com.google.android.gms:play-services-mlkit-document-scanner:16.0.0")
    // CHANGE #306 — MediboMessagingService extends FirebaseMessagingService in
    // THIS module, so the symbol has to be on the app's own compile classpath.
    // The firebase_messaging plugin already puts the artifact in the APK, but a
    // plugin's `implementation` dependency is not visible to the app module —
    // the release build failed with "Unresolved reference
    // 'FirebaseMessagingService'" until this line existed. The BoM version is
    // the one firebase_core pins (FirebaseSDKVersion=33.16.0 in its
    // gradle.properties), so this resolves to the SAME firebase-messaging the
    // plugin resolves and adds no second copy. Bump it with the plugin, never
    // on its own.
    implementation(platform("com.google.firebase:firebase-bom:33.16.0"))
    implementation("com.google.firebase:firebase-messaging")
    // CHANGE #700 — RunLocationService. play-services-location is a pure
    // JVM/AAR artifact with no native libraries, so it neither pulls an NDK
    // toolchain (this host cannot download one) nor changes the 16 KB
    // page-size alignment of the shipped APK. androidx.core supplies
    // ContextCompat.startForegroundService and ActivityCompat.requestPermissions,
    // both used by MainActivity's run_location channel.
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
