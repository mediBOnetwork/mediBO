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
                    // CHANGE #307 — the device's own answer about the
                    // full-screen-intent grant, and the one Settings screen
                    // that can change it. No wording here: Dart wraps these
                    // facts in the sentences order_alert_fsi() returned.
                    "fullScreenState" -> {
                        result.success(
                            mapOf(
                                "supported" to OrderAlert.fullScreenIsAskable(),
                                "granted" to OrderAlert.canFullScreen(applicationContext),
                                "sdk" to android.os.Build.VERSION.SDK_INT,
                            ),
                        )
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

        // CHANGE #700 — the run-location foreground service. This bridge holds
        // no policy of its own: interval, distance filter, battery threshold
        // and every word on the notification arrive in the start payload,
        // having come from delivery_live_config().
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "in.medibo.app/run_location")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(true)

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

                    "start" -> {
                        if (!hasFineLocation()) {
                            requestFineLocation()
                            result.success(false)
                        } else {
                            val i = Intent(this, RunLocationService::class.java)
                            i.action = RunLocationService.ACTION_START
                            i.putExtra("supabase_url", call.argument<String>("supabase_url") ?: "")
                            i.putExtra("anon_key", call.argument<String>("anon_key") ?: "")
                            i.putExtra("access_token", call.argument<String>("access_token") ?: "")
                            i.putExtra("refresh_token", call.argument<String>("refresh_token") ?: "")
                            i.putExtra("interval_s", call.argument<Int>("interval_s") ?: 5)
                            i.putExtra("min_move_m", call.argument<Int>("min_move_m") ?: 20)
                            i.putExtra("battery_saver_pct", call.argument<Int>("battery_saver_pct") ?: 20)
                            i.putExtra("battery_interval_s", call.argument<Int>("battery_interval_s") ?: 30)
                            i.putExtra("notif_title", call.argument<String>("notif_title") ?: "")
                            i.putExtra("notif_body", call.argument<String>("notif_body") ?: "")
                            i.putExtra("channel_name", call.argument<String>("channel_name") ?: "")
                            ContextCompat.startForegroundService(this, i)
                            result.success(true)
                        }
                    }

                    // A run outlives an access token. Dart pushes every refreshed
                    // session through so the service never has to guess.
                    "token" -> {
                        val i = Intent(this, RunLocationService::class.java)
                        i.action = RunLocationService.ACTION_TOKEN
                        i.putExtra("access_token", call.argument<String>("access_token") ?: "")
                        i.putExtra("refresh_token", call.argument<String>("refresh_token") ?: "")
                        try { ContextCompat.startForegroundService(this, i) } catch (_: Throwable) { }
                        result.success(true)
                    }

                    "stop" -> {
                        val i = Intent(this, RunLocationService::class.java)
                        i.action = RunLocationService.ACTION_STOP
                        // Start-then-stop, not stopService: a service that was
                        // never started still has to be stoppable.
                        try { ContextCompat.startForegroundService(this, i) } catch (_: Throwable) { }
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
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
