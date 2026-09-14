package `in`.medibo.app

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.Intent
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
        return stringSet(ctx, K_PACKAGES).contains(pkg)
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
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        try {
            val pkg = n.packageName ?: return
            if (pkg == packageName) return
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
}
