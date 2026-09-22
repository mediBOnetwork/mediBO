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
    // CMD #2131 (per #2147) — header + dock motion at the screen's highest
    // refresh rate. Android runs apps at 60 Hz unless the window asks, so ask
    // for the fastest mode at the CURRENT resolution (120 Hz where the phone
    // has it). Mechanics only; a phone with one mode keeps it.
    override fun onResume() {
        super.onResume()
        requestHighestRefreshRate()
    }

    private fun requestHighestRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            @Suppress("DEPRECATION")
            val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                this.display
            } else {
                windowManager.defaultDisplay
            } ?: return
            val cur = display.mode
            val best = display.supportedModes
                .filter {
                    it.physicalWidth == cur.physicalWidth &&
                        it.physicalHeight == cur.physicalHeight
                }
                .maxByOrNull { it.refreshRate } ?: return
            val attrs = window.attributes
            if (attrs.preferredDisplayModeId == best.modeId) return
            attrs.preferredDisplayModeId = best.modeId
            window.attributes = attrs
        } catch (_: Throwable) {
            // Never let a display quirk stop the app opening.
        }
    }

    // CMD #2151 — Phone Number Hint returns through the activity result.
    @Deprecated("FlutterActivity still routes results through onActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (PhoneHint.onResult(this, requestCode, resultCode, data)) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // CHANGE #225 — readiness gate for the on-demand ML Kit document-scanner
        // module, so Dart can check/install before launching Google's activity.
        DocScanReadiness.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // CHANGE #275 — the running APK's signing SHA-1 / package / versionCode,
        // attached to every recorded sign-in failure. Play re-signs the upload,
        // so this is the one fact that tells a Play build from a sideloaded one.
        SignInDiag.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // CMD #2028 — Play In-App Updates behind the floating update pill.
        // Needs the ACTIVITY (Play's flow is launched for a result), which is
        // why it is registered here and not from applicationContext.
        PlayUpdate.register(flutterEngine.dartExecutor.binaryMessenger, this)
        // CMD #2151 — registration's WhatsApp box: the phone's own number list.
        PhoneHint.register(flutterEngine.dartExecutor.binaryMessenger, this)
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
                            // CMD #2050 — the phone's own name, so a paired
                            // device is recognisable in the Devices list. It is
                            // data Android reports, never a label Dart invents.
                            "model" to listOf(
                                android.os.Build.MANUFACTURER.orEmpty(),
                                android.os.Build.MODEL.orEmpty(),
                            ).filter { it.isNotBlank() }.joinToString(" "),
                            "sdk" to android.os.Build.VERSION.SDK_INT,
                            // CMD #2067 — the grant and the BIND are separate
                            // facts. bound_at is set by onListenerConnected and
                            // is the only proof Android actually started us;
                            // allow_count is 0 on a phone that has never been
                            // handed payment_listener_boot().packages, which is
                            // what made a granted phone deaf on 17 Sep.
                            "bound_at" to PaymentListener.boundAt(applicationContext),
                            "binds" to PaymentListener.bindCount(applicationContext),
                            "allow_count" to PaymentListener.allowCount(applicationContext),
                            // What Play knows this build as. Reported so the
                            // Devices list can name the version a phone is on
                            // without the app inventing a string.
                            "app_version" to appVersionLabel(),
                        ),
                    )
                    "openSettings" -> result.success(PaymentListener.openSettings(applicationContext))
                    // CMD #2067 item 4 — force the listener to start when the
                    // grant is on but Android never bound it (ColorOS/MIUI).
                    "rebind" -> result.success(PaymentListener.rebind(applicationContext))
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
                    // CMD #2093 — the phone notification for a credit. Both
                    // strings arrive worded from payment_alert_speak_pull; the
                    // id is the speak row's, so the same payment never posts
                    // twice and a re-pull replaces rather than stacks.
                    "notify" -> {
                        PaymentListener.notifyPayment(
                            applicationContext,
                            call.argument<Int>("id") ?: 0,
                            call.argument<String>("title") ?: "",
                            call.argument<String>("body") ?: "",
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

                    // CMD #2171 — the answer now comes back when the PERSON has
                    // given it. The old handler raised the dialog and replied
                    // false in the same breath, which was fine for the rider
                    // loop (it re-asks) but meant a caller that awaits this —
                    // the registration Location step — read "refused" while the
                    // dialog was still on screen. onRequestPermissionsResult
                    // completes it.
                    "requestPermission" -> {
                        if (hasFineLocation()) {
                            result.success(true)
                        } else {
                            pendingLocationPermission?.success(false)
                            pendingLocationPermission = result
                            requestFineLocation()
                        }
                    }

                    // CMD #2171 — ONE fix, for a caller that only wants to know
                    // where the phone is (the shop pin). Nothing is decided
                    // here: it is the platform's coordinate or nothing.
                    "fix" -> oneLocationFix(
                        (call.argument<Int>("timeout_ms") ?: 8000).toLong(),
                        (call.argument<Double>("good_enough_m") ?: 25.0),
                        result,
                    )

                    // CMD #2171 — for a grant Android will not ask about again.
                    "openSettings" -> result.success(openAppSettings())

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
    /** versionName (versionCode), straight from the installed package. */
    private fun appVersionLabel(): String = try {
        val pi = applicationContext.packageManager
            .getPackageInfo(applicationContext.packageName, 0)
        val code = if (android.os.Build.VERSION.SDK_INT >= 28) {
            pi.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            pi.versionCode.toLong()
        }
        "${pi.versionName} ($code)"
    } catch (_: Throwable) {
        ""
    }

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
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * CMD #2171 — the pending "requestPermission" call, completed from
     * onRequestPermissionsResult with what the person actually chose.
     */
    private var pendingLocationPermission: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 7002) {
            val pending = pendingLocationPermission
            pendingLocationPermission = null
            try {
                pending?.success(hasFineLocation())
            } catch (_: Throwable) {
                // The engine can be gone by the time the sheet is answered.
            }
        }
    }

    /**
     * CMD #2171 — ONE location fix, or null.
     *
     * Plain LocationManager, no Play-Services dependency: it listens on every
     * enabled provider for [timeoutMs], keeps the tightest reading it sees and
     * answers early once that reading is inside [goodEnoughM]. A phone whose
     * providers never fire falls back to the last known position, and a phone
     * with nothing at all answers null — which the screen already draws as its
     * amber "location is off" bar.
     */
    private fun oneLocationFix(timeoutMs: Long, goodEnoughM: Double, result: MethodChannel.Result) {
        if (!hasFineLocation()) { result.success(null); return }
        val lm = getSystemService(android.content.Context.LOCATION_SERVICE) as? android.location.LocationManager
        if (lm == null) { result.success(null); return }

        val answered = java.util.concurrent.atomic.AtomicBoolean(false)
        var best: android.location.Location? = null
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        var listener: android.location.LocationListener? = null
        var timeout: Runnable? = null

        fun reply() {
            if (answered.getAndSet(true)) return
            timeout?.let { main.removeCallbacks(it) }
            listener?.let { l -> try { lm.removeUpdates(l) } catch (_: Throwable) {} }
            val loc = best
            val payload: Map<String, Any>? = if (loc == null) {
                null
            } else {
                hashMapOf<String, Any>(
                    "lat" to loc.latitude,
                    "lng" to loc.longitude,
                    "accuracy" to loc.accuracy.toDouble(),
                )
            }
            try { result.success(payload) } catch (_: Throwable) {}
        }

        fun offer(loc: android.location.Location?) {
            if (loc == null) return
            if (loc.latitude == 0.0 && loc.longitude == 0.0) return
            val have = best
            if (have == null || loc.accuracy <= have.accuracy) best = loc
            val acc = best?.accuracy ?: return
            if (acc <= goodEnoughM) reply()
        }

        // A last known position is the floor, never the answer on its own: a
        // remembered fix from another part of town is exactly what a shop pin
        // must not be built on, so a live reading still gets its window.
        val providers = try { lm.getProviders(true) } catch (_: Throwable) { emptyList<String>() }
        for (p in providers) {
            try {
                @Suppress("MissingPermission")
                val last = lm.getLastKnownLocation(p)
                if (last != null && android.os.SystemClock.elapsedRealtime() -
                    (last.elapsedRealtimeNanos / 1_000_000L) < 120_000L
                ) {
                    val have = best
                    if (have == null || last.accuracy <= have.accuracy) best = last
                }
            } catch (_: Throwable) {}
        }

        val l = object : android.location.LocationListener {
            override fun onLocationChanged(location: android.location.Location) = offer(location)
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
            @Deprecated("Required by the pre-30 interface")
            override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        }
        listener = l
        var listening = false
        for (p in providers) {
            try {
                @Suppress("MissingPermission")
                lm.requestLocationUpdates(p, 0L, 0f, l, android.os.Looper.getMainLooper())
                listening = true
            } catch (_: Throwable) {}
        }
        if (!listening && best == null) { reply(); return }

        val t = Runnable { reply() }
        timeout = t
        main.postDelayed(t, timeoutMs.coerceIn(2000L, 30000L))
    }

    /** CMD #2171 — this app's own page in system Settings. */
    private fun openAppSettings(): Boolean = try {
        startActivity(
            android.content.Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.parse("package:${applicationContext.packageName}"),
            ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (_: Throwable) {
        false
    }

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
