package `in`.medibo.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
        // CHANGE #306 — the channels must exist before the first alert lands,
        // and the app must be able to stop the ringing and clear the sticky
        // line the moment an order is actioned inside the app. Every word the
        // channel shows arrives from the backend through this seam.
        OrderAlert.ensureChannels(applicationContext, null, null)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "medibo/order_alert")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureChannels" -> {
                        OrderAlert.ensureChannels(
                            applicationContext,
                            call.argument<String>("name"),
                            call.argument<String>("description"),
                        )
                        result.success(true)
                    }
                    "stopRinging" -> {
                        OrderAlert.stopRinging(applicationContext)
                        result.success(true)
                    }
                    "clear" -> {
                        val nm = getSystemService(android.app.NotificationManager::class.java)
                        val id = call.argument<Int>("alert_id")
                        if (id != null) nm?.cancel(OrderAlert.notificationId(id.toLong()))
                        OrderAlert.stopRinging(applicationContext)
                        result.success(true)
                    }
                    "ongoing" -> {
                        // The sticky count is the BACKEND's number, handed
                        // straight through — never counted in Dart.
                        val json = org.json.JSONObject()
                        json.put("pending_count", call.argument<Int>("count") ?: 0)
                        json.put("ongoing_title", call.argument<String>("title") ?: "")
                        json.put("ongoing_body", call.argument<String>("body") ?: "")
                        OrderAlert.showOngoing(applicationContext, json)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
