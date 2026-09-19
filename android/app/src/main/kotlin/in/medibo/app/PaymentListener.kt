package `in`.medibo.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.speech.tts.TextToSpeech
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * CMD #1931 — the Android half of "hear every payment".
 *
 * The service reads notifications ONLY from the packages the BACKEND listed
 * (payment_listener_boot().packages, written here by Dart). Everything else is
 * dropped on the phone before it is ever looked at. A kept line is appended to
 * a small on-disk queue, so a payment that arrives with no network — or with
 * the app dead — is still delivered the next time Dart runs.
 *
 * Nothing in this file words anything. The spoken sentence is built by
 * payment_alert_speak/payment_alert_speak_pull and handed down verbatim.
 */
object PaymentListener {
    const val PREFS = "medibo_pay_listen"
    private const val K_PACKAGES = "packages"
    private const val K_IGNORE = "ignore"
    private const val K_QUEUE = "queue"
    private const val K_MAX = "queue_max"
    private const val K_SEQ = "seq"

    // CMD #2067 — the grant and the BIND are two different facts. On ColorOS
    // and MIUI a listener can be "allowed" in Settings and never started, and
    // that is exactly the shape of the 17 Sep failure: access ON, nothing
    // heard. onListenerConnected is the only honest answer, so it is recorded
    // here and reported to the backend as listener_bound_at.
    private const val K_BOUND_AT = "bound_at"
    private const val K_BINDS = "binds"

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The allow-list, exactly as the backend sent it. No default, ever. */
    fun setPackages(ctx: Context, packages: List<String>, ignore: List<String>, queueMax: Int) {
        val a = JSONArray(); packages.forEach { a.put(it) }
        val b = JSONArray(); ignore.forEach { b.put(it) }
        prefs(ctx).edit()
            .putString(K_PACKAGES, a.toString())
            .putString(K_IGNORE, b.toString())
            .putInt(K_MAX, if (queueMax > 0) queueMax else 500)
            .apply()
    }

    private fun stringSet(ctx: Context, key: String): Set<String> {
        val raw = prefs(ctx).getString(key, null) ?: return emptySet()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { arr.optString(it, null) }.toSet()
        } catch (_: Throwable) {
            emptySet()
        }
    }

    fun allows(ctx: Context, pkg: String): Boolean {
        if (pkg.isBlank()) return false
        if (stringSet(ctx, K_IGNORE).contains(pkg)) return false
        val allowed = stringSet(ctx, K_PACKAGES)
        // CMD #2067 — payment_alert_rules carries a "*" rule, and the backend
        // hands it down inside packages[]. It means every app; an exact-set
        // match silently dropped it, so a shop whose bank app was not on the
        // list heard nothing. The wildcard is the BACKEND's decision, honoured
        // here, never invented here.
        if (allowed.contains("*")) return true
        return allowed.contains(pkg)
    }

    /** How many packages the backend has told this phone about. 0 = deaf. */
    fun allowCount(ctx: Context): Int = stringSet(ctx, K_PACKAGES).size

    /** When Android last actually STARTED the listener service. 0 = never. */
    fun boundAt(ctx: Context): Long = prefs(ctx).getLong(K_BOUND_AT, 0L)

    fun bindCount(ctx: Context): Int = prefs(ctx).getInt(K_BINDS, 0)

    fun markBound(ctx: Context, bound: Boolean) {
        val p = prefs(ctx)
        if (bound) {
            p.edit()
                .putLong(K_BOUND_AT, System.currentTimeMillis())
                .putInt(K_BINDS, p.getInt(K_BINDS, 0) + 1)
                .apply()
        } else {
            p.edit().putLong(K_BOUND_AT, 0L).apply()
        }
    }

    /**
     * CMD #2067 item 4 — force Android to bind the service.
     *
     * A grant given while the app is in the foreground does not always start
     * the listener on OEM builds (ColorOS, MIUI, ColorOS-derived HyperOS).
     * Toggling the component's enabled state makes the system tear the
     * registration down and build it again, which is the documented way to
     * recover a listener that was never connected. requestRebind is the polite
     * path and is tried first.
     */
    fun rebind(ctx: Context): Boolean {
        val cn = ComponentName(ctx, PaymentNotificationListenerService::class.java)
        var ok = false
        if (Build.VERSION.SDK_INT >= 24) {
            try {
                NotificationListenerService.requestRebind(cn)
                ok = true
            } catch (_: Throwable) {
                // fall through to the hard toggle
            }
        }
        try {
            val pm = ctx.packageManager
            pm.setComponentEnabledSetting(
                cn,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
            pm.setComponentEnabledSetting(
                cn,
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
            ok = true
        } catch (_: Throwable) {
            // A locked-down OEM may refuse; requestRebind may still have taken.
        }
        return ok
    }

    /** Has the user granted notification access to THIS app? */
    fun isEnabled(ctx: Context): Boolean {
        val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
            ?: return false
        val me = ctx.packageName
        return flat.split(":").any { entry ->
            val cn = ComponentName.unflattenFromString(entry)
            cn != null && cn.packageName == me
        }
    }

    /** The one system screen where the grant can be given or taken away. */
    fun openSettings(ctx: Context): Boolean {
        val candidates = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= 30) {
            candidates.add(
                Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS).putExtra(
                    Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                    ComponentName(ctx, PaymentNotificationListenerService::class.java).flattenToString(),
                ),
            )
        }
        candidates.add(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        candidates.add(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${ctx.packageName}"),
            ),
        )
        for (i in candidates) {
            try {
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(i)
                return true
            } catch (_: Throwable) {
                // try the next one
            }
        }
        return false
    }

    // ── the offline queue ───────────────────────────────────────────────────
    @Synchronized
    fun enqueue(ctx: Context, pkg: String, title: String, text: String, postedAtMs: Long) {
        val p = prefs(ctx)
        val max = p.getInt(K_MAX, 500)
        val arr = try { JSONArray(p.getString(K_QUEUE, "[]")) } catch (_: Throwable) { JSONArray() }
        val seq = p.getLong(K_SEQ, 0L) + 1L
        val o = JSONObject()
            .put("qid", seq)
            .put("package", pkg)
            .put("title", title)
            .put("text", text)
            .put("posted_at_ms", postedAtMs)
        arr.put(o)
        // Oldest out first when the queue is full: a fresh payment matters more
        // than one the phone has already failed to send for hours.
        val trimmed = if (arr.length() > max) {
            val out = JSONArray()
            for (i in (arr.length() - max) until arr.length()) out.put(arr.get(i))
            out
        } else {
            arr
        }
        p.edit().putString(K_QUEUE, trimmed.toString()).putLong(K_SEQ, seq).apply()
    }

    @Synchronized
    fun drain(ctx: Context, limit: Int): String {
        val arr = try {
            JSONArray(prefs(ctx).getString(K_QUEUE, "[]"))
        } catch (_: Throwable) {
            JSONArray()
        }
        val out = JSONArray()
        var i = 0
        while (i < arr.length() && i < limit) { out.put(arr.get(i)); i++ }
        return out.toString()
    }

    @Synchronized
    fun ack(ctx: Context, qids: Set<Long>) {
        val p = prefs(ctx)
        val arr = try { JSONArray(p.getString(K_QUEUE, "[]")) } catch (_: Throwable) { JSONArray() }
        val out = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (!qids.contains(o.optLong("qid", -1L))) out.put(o)
        }
        p.edit().putString(K_QUEUE, out.toString()).apply()
    }

    @Synchronized
    fun queueCount(ctx: Context): Int = try {
        JSONArray(prefs(ctx).getString(K_QUEUE, "[]")).length()
    } catch (_: Throwable) {
        0
    }

    // ── the voice ───────────────────────────────────────────────────────────
    private var tts: TextToSpeech? = null
    private val pending = mutableListOf<Pair<String, Float>>()

    /**
     * Speak [text] at [volume] (0-100, the backend's per-device setting).
     * The engine takes a moment to come up on first use, so anything said
     * before it is ready is queued rather than dropped.
     */
    @Synchronized
    fun speak(ctx: Context, text: String, volume: Int) {
        if (text.isBlank()) return
        val vol = (volume.coerceIn(0, 100)) / 100f
        val engine = tts
        if (engine != null) {
            say(engine, text, vol)
            return
        }
        pending.add(text to vol)
        tts = TextToSpeech(ctx.applicationContext) { status ->
            synchronized(this) {
                val e = tts
                if (status == TextToSpeech.SUCCESS && e != null) {
                    try {
                        // en-IN reads "₹500" and an Indian shop name far better
                        // than the default locale on most handsets.
                        e.language = Locale("en", "IN")
                    } catch (_: Throwable) {
                        // keep whatever the engine defaulted to
                    }
                    pending.forEach { (t, v) -> say(e, t, v) }
                } else {
                    tts = null
                }
                pending.clear()
            }
        }
    }

    // ── the phone notification ──────────────────────────────────────────────
    // CMD #2093 — speaking is not enough: a phone on silent, or one with no
    // TTS engine, announced nothing at all. Every accepted credit now also
    // posts a normal Android notification whose TITLE and BODY are the
    // backend's words (payment_alert_speak.notify_title / notify_body),
    // carried down by payment_alert_speak_pull and passed through verbatim.
    private const val CHANNEL_ID = "medibo_payments"

    private fun channel(ctx: Context): NotificationManager {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val existing = nm.getNotificationChannel(CHANNEL_ID)
            if (existing == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        // The channel's own name is the one string Android
                        // shows in its settings list; it is not per-payment
                        // copy and cannot come down with a payment.
                        "Payments received",
                        NotificationManager.IMPORTANCE_HIGH,
                    ),
                )
            }
        }
        return nm
    }

    /** Post one payment notification. [title] and [body] are already worded. */
    fun notifyPayment(ctx: Context, id: Int, title: String, body: String) {
        if (body.isBlank()) return
        try {
            val nm = channel(ctx)
            val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            val pi = if (open == null) null else PendingIntent.getActivity(
                ctx, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val n = Notification.Builder(ctx, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setSmallIcon(ctx.applicationInfo.icon)
                .setAutoCancel(true)
                .also { b -> if (pi != null) b.setContentIntent(pi) }
                .build()
            nm.notify(id, n)
        } catch (_: Throwable) {
            // A handset that refuses the post still gets the spoken line and
            // the row on the Payment alerts screen.
        }
    }

    private fun say(engine: TextToSpeech, text: String, vol: Float) {
        val params = Bundle().apply { putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, vol) }
        try {
            engine.speak(text, TextToSpeech.QUEUE_ADD, params, "medibo-pay-${System.currentTimeMillis()}")
        } catch (_: Throwable) {
            // A phone with no TTS engine still gets the on-screen line.
        }
    }
}

/**
 * The service itself. It does the least possible: allow-list check, then queue.
 * Parsing, matching and every word spoken happen in the backend.
 */
class PaymentNotificationListenerService : NotificationListenerService() {
    /**
     * CMD #2067 item 2 — the proof that the service is actually running. Until
     * this fires, notification access being "ON" in Settings means nothing.
     * The timestamp is read back through the method channel and reported to
     * payment_alert_device_register(p_bound), so the Devices card can say
     * "Listening on" only when Android really did start us.
     */
    override fun onListenerConnected() {
        super.onListenerConnected()
        try {
            PaymentListener.markBound(applicationContext, true)
            android.util.Log.i(TAG, "onListenerConnected — payment listener bound")
        } catch (_: Throwable) {
            // never let bookkeeping kill the listener
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        try {
            PaymentListener.markBound(applicationContext, false)
            android.util.Log.w(TAG, "onListenerDisconnected — asking Android to rebind")
            if (Build.VERSION.SDK_INT >= 24) {
                requestRebind(ComponentName(this, PaymentNotificationListenerService::class.java))
            }
        } catch (_: Throwable) {
            // nothing else to try
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        try {
            val pkg = n.packageName ?: return
            if (pkg == packageName) return
            if (PaymentListener.allowCount(applicationContext) == 0) {
                // CMD #2067 — the 17 Sep failure, stated out loud. An empty
                // allow-list means Dart has never run payment_listener_boot()
                // on this phone, so EVERY payment is dropped here. It is not a
                // parser problem and it is not a permission problem.
                android.util.Log.w(TAG, "allow-list empty — open mediBO once to pair; dropping $pkg")
                return
            }
            if (!PaymentListener.allows(applicationContext, pkg)) return
            val extras: Bundle = n.notification?.extras ?: return
            val title = (extras.getCharSequence(Notification.EXTRA_TITLE) ?: "").toString()
            val body = (
                extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                    ?: extras.getCharSequence(Notification.EXTRA_TEXT)
                    ?: ""
                ).toString()
            if (title.isBlank() && body.isBlank()) return
            PaymentListener.enqueue(applicationContext, pkg, title, body, n.postTime)
        } catch (_: Throwable) {
            // A listener that throws is killed by Android; never let one
            // malformed notification take the whole service down.
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) { /* nothing to do */ }

    companion object {
        private const val TAG = "mediBO/pay"
    }
}
