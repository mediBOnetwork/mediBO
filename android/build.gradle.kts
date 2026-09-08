allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// ── 16 KB PAGE SIZE (CHANGE #278) ────────────────────────────────────────────
// Android 15+ devices use 16 KB memory pages and Play REFUSES an upload whose
// 64-bit native libraries have ELF load segments aligned below 16384. This
// project compiles no native code of its own — every .so arrives prebuilt
// inside a third-party AAR — so the only fix is to resolve versions that were
// already built 16 KB aligned:
//
//   androidx.camera:*                1.3.3  -> 1.4.2   (libimage_processing_util_jni.so
//                                                       and libsurface_util_jni.so)
//   com.google.mlkit:barcode-scanning 17.2.0 -> 17.3.0 (libbarhopper_v3.so)
//
// Both old versions were pinned by the mobile_scanner plugin, which is its OWN
// Gradle subproject — forcing them in :app alone would fix what gets PACKAGED
// but leave the plugin compiling against the old API, so this is applied to
// every project. armeabi-v7a stays 4 KB aligned by design: the 16 KB page size
// is a 64-bit-only requirement and Play only checks arm64-v8a / x86_64.
//
// Verify with scripts/check_16kb.py after any dependency change — a silently
// re-resolved older version is exactly how a build regresses back to blocked.
allprojects {
    configurations.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "androidx.camera") {
                useVersion("1.4.2")
                because("16 KB aligned native libs (CHANGE #278)")
            }
            if (requested.group == "com.google.mlkit" && requested.name == "barcode-scanning") {
                useVersion("17.3.0")
                because("16 KB aligned libbarhopper_v3.so (CHANGE #278)")
            }
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
