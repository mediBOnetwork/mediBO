package `in`.medibo.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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
                    // CMD #2015 — the order alert no longer raises a
                    // full-screen intent at all, so there is no grant to ask
                    // for and nothing for the device card to prompt. The seam
                    // stays (Dart and the backend copy still ask) and answers
                    // honestly: not supported, not granted.
                    "fullScreenState" -> {
                        result.success(
                            mapOf(
                                "supported" to false,
                                "granted" to false,
                                "sdk" to android.os.Build.VERSION.SDK_INT,
                            ),
                        )
                    }
                    // CMD #2015 item 1 — the server is the only authority on
                    // which alerts exist. Dart passes order_alert_reconcile()'s
                    // list straight through; anything else on this phone is
                    // cancelled and every sound stops.
                    "reconcile" -> {
                        val ids = (call.argument<List<Number>>("live_ids") ?: emptyList())
                            .map { it.toLong() }
                            .toSet()
                        OrderAlert.reconcile(
                            applicationContext,
                            ids,
                            call.argument<Boolean>("mute_all") ?: false,
                        )
                        result.success(true)
                    }
                    "openFullScreenSettings" -> {
                        result.success(openFullScreenSettings())
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

        // CMD #1931 — the payment-notification listener bridge. Every word
        // and every package name arrives from the backend through this seam;
        // Kotlin only reports what Android says and queues what it is allowed
        // to see. The spoken sentence is payment_alert_speak's, spoken as-is.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "medibo/pay_listen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "state" -> result.success(
                        mapOf(
                            "granted" to PaymentListener.isEnabled(applicationContext),
                            "queued" to PaymentListener.queueCount(applicationContext),
                            "device_id" to deviceId(),
                            "sdk" to android.os.Build.VERSION.SDK_INT,
                        ),
                    )
                    "openSettings" -> result.success(PaymentListener.openSettings(applicationContext))
                    "setPackages" -> {
                        PaymentListener.setPackages(
                            applicationContext,
                            call.argument<List<String>>("packages") ?: emptyList(),
                            call.argument<List<String>>("ignore") ?: emptyList(),
                            call.argument<Int>("queue_max") ?: 500,
                        )
                        result.success(true)
                    }
                    "drain" -> result.success(
                        PaymentListener.drain(applicationContext, call.argument<Int>("limit") ?: 25),
                    )
                    "ack" -> {
                        val ids = (call.argument<List<Number>>("qids") ?: emptyList())
                            .map { it.toLong() }.toSet()
                        PaymentListener.ack(applicationContext, ids)
                        result.success(PaymentListener.queueCount(applicationContext))
                    }
                    "speak" -> {
                        PaymentListener.speak(
                            applicationContext,
                            call.argument<String>("text") ?: "",
                            call.argument<Int>("volume") ?: 100,
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // CHANGE #700 / #985 — the run-location bridge. The foreground
        // location service was removed for the 1.3.21 (35) Play release (Play
        // requires a Console-only foreground-service declaration for it), so
        // this bridge now answers "not available": Dart's RunLocationService
        // keeps the rider run screen on its in-app polling loop. Permission
        // helpers stay so the in-app loop can still be granted fine location.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "in.medibo.app/run_location")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(false)

                    "hasPermission" -> result.success(hasFineLocation())

                    "requestPermission" -> {
                        if (hasFineLocation()) {
                            result.success(true)
                        } else {
                            requestFineLocation()
                            // The grant lands asynchronously in the system
                            // dialog; Dart re-asks with hasPermission before it
                            // starts. Never block on a permission sheet.
                            result.success(false)
                        }
                    }

                    // No foreground service in this build: refuse the start so
                    // Dart keeps its in-app loop; token/stop have nothing to do.
                    "start" -> result.success(false)
                    "token" -> result.success(true)
                    "stop" -> result.success(true)

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * CMD #1931 — a stable id for THIS phone, so the backend can hold one row
     * of listener settings per device. ANDROID_ID is per app-signing-key and
     * per user, survives updates, and is reset by a factory reset — exactly
     * the lifetime a "does this phone speak?" switch should have.
     */
    @android.annotation.SuppressLint("HardwareIds")
    private fun deviceId(): String = try {
        android.provider.Settings.Secure.getString(
            applicationContext.contentResolver,
            android.provider.Settings.Secure.ANDROID_ID,
        ) ?: ""
    } catch (_: Throwable) {
        ""
    }

    private fun hasFineLocation(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestFineLocation() {
        val perms = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        ActivityCompat.requestPermissions(this, perms.toTypedArray(), 7002)
    }

    /**
     * CHANGE #307 — Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT is the
     * only place this grant can be given (API 34+). If the OEM has no such
     * screen, fall back to the app's notification settings rather than
     * throwing an activity-not-found at an admin who tapped a button.
     */
    private fun openFullScreenSettings(): Boolean {
        val pkg = applicationContext.packageName
        val candidates = mutableListOf<android.content.Intent>()
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            candidates.add(
                android.content.Intent(
                    android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                    android.net.Uri.parse("package:$pkg"),
                ),
            )
        }
        candidates.add(
            android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, pkg),
        )
        candidates.add(
            android.content.Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.parse("package:$pkg"),
            ),
        )
        for (i in candidates) {
            try {
                i.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(i)
                return true
            } catch (_: Throwable) {
                // try the next one
            }
        }
        return false
    }
}
