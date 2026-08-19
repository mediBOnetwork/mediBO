package `in`.medibo.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // CHANGE #225 — readiness gate for the on-demand ML Kit document-scanner
        // module, so Dart can check/install before launching Google's activity.
        DocScanReadiness.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // CHANGE #275 — the running APK's signing SHA-1 / package / versionCode,
        // attached to every recorded sign-in failure. Play re-signs the upload,
        // so this is the one fact that tells a Play build from a sideloaded one.
        SignInDiag.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
