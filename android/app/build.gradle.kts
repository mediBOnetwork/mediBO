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

// CMD #2100 — the PARTNER flavor (in.medibo.partner) signs with its OWN upload
// keystore: android/key.partner.properties + upload-keystore-partner.jks, both
// gitignored and both restored from the Vault (ANDROID_PARTNER_UPLOAD_KEYSTORE_B64
// / ANDROID_PARTNER_KEY_PROPERTIES) by ~/mediBO-runner/restore_keystore.sh partner.
val partnerKeystoreProperties = Properties()
val partnerKeystorePropertiesFile = rootProject.file("key.partner.properties")
val hasPartnerKeystore = partnerKeystorePropertiesFile.exists()
if (hasPartnerKeystore) {
    partnerKeystoreProperties.load(FileInputStream(partnerKeystorePropertiesFile))
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
        // CMD #2076 — Firebase Test Lab drives integration_test/android_gate_test.dart
        // through this runner (android/app/src/androidTest). Debug/androidTest only;
        // the release AAB carries none of it.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        versionCode = 55
        versionName = "1.3.34"
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
        if (hasPartnerKeystore) {
            create("partner") {
                keyAlias = partnerKeystoreProperties["keyAlias"] as String
                keyPassword = partnerKeystoreProperties["keyPassword"] as String
                storeFile = partnerKeystoreProperties["storeFile"]?.let { rootProject.file(it) }
                storePassword = partnerKeystoreProperties["storePassword"] as String
            }
        }
    }

    // ── TWO APPS, ONE CODEBASE (CMD #2100) ──────────────────────────────────
    // 'customer' is today's app, byte-for-byte: same applicationId, versions,
    // icon and upload key (it keeps the staff code too — web serves all roles).
    // 'partner' is mediBO Partner: its own applicationId, version numbers,
    // launcher icon (android/app/src/partner/res) and upload keystore. Every
    // build names its flavor: `flutter build appbundle --flavor partner`.
    // The signing config lives on the FLAVOR (a build-type signingConfig would
    // override it for both), so the release build type below sets none.
    flavorDimensions += listOf("app")
    productFlavors {
        create("customer") {
            dimension = "app"
            isDefault = true
            resValue("string", "app_name", "mediBO")
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        create("partner") {
            dimension = "app"
            applicationId = "in.medibo.partner"
            versionCode = 3
            versionName = "1.0.2"
            resValue("string", "app_name", "mediBO Partner")
            if (hasPartnerKeystore) {
                signingConfig = signingConfigs.getByName("partner")
            }
        }
    }

    buildTypes {
        release {
            // NOTE: on a missing keystore this still assigns debug so the project
            // configures cleanly, but the gradle.taskGraph guard below HARD-FAILS
            // any *Release assemble/bundle before it can produce a debug-signed
            // release artifact (see the 1.1.0 signature-mismatch incident).
            // CMD #2100 — no signingConfig here: each product flavor above
            // carries its own upload key. A flavor whose keystore is absent
            // falls back to AGP's debug signing, which the taskGraph guard
            // below refuses for every *Release assemble/bundle/package task.
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
    // CMD #2100 — per flavor: a Partner release needs the partner keystore, a
    // Customer release the original one. Task names carry the flavor.
    val buildingPartner = allTasks.any { t ->
        t.name.contains("PartnerRelease") &&
            (t.name.startsWith("assemble") || t.name.startsWith("bundle") ||
                t.name.startsWith("package"))
    }
    val buildingCustomer = allTasks.any { t ->
        t.name.contains("CustomerRelease") &&
            (t.name.startsWith("assemble") || t.name.startsWith("bundle") ||
                t.name.startsWith("package"))
    }
    if (buildingPartner && !hasPartnerKeystore &&
        System.getenv("ALLOW_DEBUG_SIGNING") != "1") {
        throw GradleException(
            "\n❌  PARTNER RELEASE BUILD REFUSED: android/key.partner.properties is missing.\n" +
                "    Restore it with ~/mediBO-runner/restore_keystore.sh partner and retry.\n")
    }
    if (buildingRelease && (buildingCustomer || !buildingPartner) && !hasReleaseKeystore &&
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
    // CMD #2076 — the androidTest runner for Firebase Test Lab needs nothing
    // declared here: the integration_test plugin exports androidx.test
    // runner/rules as `api`, and pinning them again fails Gradle's consistent
    // resolution (checkDebugAndroidTestAarMetadata). See MainActivityTest.java.
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
    // CMD #2028 — Play In-App Updates (the floating update pill's Android
    // half). Pure JVM/AAR: no native libraries, so it neither needs an NDK on
    // this host nor changes the 16 KB page alignment the #278 gate checks.
    implementation("com.google.android.play:app-update:2.1.0")
    implementation("com.google.android.play:app-update-ktx:2.1.0")
    // CMD #2151 — Phone Number Hint (Identity API) for registration's WhatsApp
    // box. Same version google_sign_in_android already ships, so no second copy.
    implementation("com.google.android.gms:play-services-auth:21.6.0")
}

flutter {
    source = "../.."
}
