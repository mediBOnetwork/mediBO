package `in`.medibo.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * CMD #2015 — the order alert, after the endless ringtone.
 *
 * What this file used to do, and why the app had to be uninstalled to escape
 * it: the channel was built with the ALARM usage and DND bypass turned on, so
 * silent mode, vibrate mode, Do Not Disturb and the volume keys were all
 * bypassed BY DESIGN; the player looped for up to 600 s; and it was re-armed every
 * 60 s for up to 30 pushes. A synthetic (test-mode) alert then arrived naming
 * a row the phone could not see, so there was nothing on the device to tap.
 *
 * The rules now, in one place:
 *   1. NOTHING here decides that an alert exists. Every alert on this phone
 *      came from a push, and `reconcile()` — called on app start and on every
 *      foreground — cancels anything the server no longer lists.
 *   2. Channel `medibo_order_alert_v2`. An Android channel's sound, usage and
 *      DND-bypass are frozen at creation, so un-bypassing a phone that already
 *      has the app is only possible on a NEW id. The old channel is deleted.
 *   3. The sound is USAGE_NOTIFICATION_RINGTONE (STREAM_RING) and is never
 *      looped. Silent mode, vibrate mode, DND and a zero ring volume are each
 *      checked before a note is played, and a volume key or a ringer-mode
 *      change stops it mid-note.
 *   4. A hard cap. The backend counts rings and stops at ring_cap; this file
 *      counts them too, per alert, in SharedPreferences, and refuses ring
 *      cap + 1 even if a push asks for it. The notification stays; it is silent.
 *   5. Every notification carries Stop. It kills the sound, clears the alert,
 *      marks it permanently silent on this device and tells the server.
 *
 * Every word shown is still the backend's, out of the `alert` blob.
 */
object OrderAlert {
    /** The un-bypassable channel this change replaced. Deleted on sight. */
    private const val CHANNEL_LEGACY = "medibo_order_alert"
    const val CHANNEL_ALERT = "medibo_order_alert_v2"
    const val CHANNEL_ONGOING = "medibo_order_ongoing"
    const val ONGOING_ID = 306_000
    private const val TAG = "OrderAlert"
    private const val PREFS = "medibo_order_alert"
    private const val KEY_RINGS = "rings_"
    private const val KEY_STOPPED = "stopped_"
    private const val KEY_LIVE = "live_ids"

    /** A single note never outlives this, whatever a payload asks for. */
    private const val MAX_RING_MS = 20_000L

    const val EXTRA_TOKEN = "oa_token"
    const val EXTRA_ACTION = "oa_action"
    const val EXTRA_URL = "oa_url"
    const val EXTRA_NOTIF_ID = "oa_notif_id"
    const val EXTRA_ALERT_ID = "oa_alert_id"
    const val ACTION_STOP = "in.medibo.app.ORDER_ALERT_STOP"

    private var player: MediaPlayer? = null
    private val handler = Handler(Looper.getMainLooper())
    private var silencer: SilenceWatcher? = null

    fun notificationId(alertId: Long): Int = (306_100 + (alertId % 800)).toInt()

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * Channels are created early and idempotently: at boot and on every alert.
     * The alert channel makes no sound of its own — this object plays the note,
     * so there is exactly one thing to stop.
     */
    fun ensureChannels(ctx: Context, name: String?, description: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return

        // The alarm-usage, DND-bypassing channel from CHANGE #306. Its settings
        // cannot be edited, so it is removed rather than reused.
        try {
            nm.deleteNotificationChannel(CHANNEL_LEGACY)
        } catch (_: Throwable) {
        }

        val alert = NotificationChannel(
            CHANNEL_ALERT,
            if (name.isNullOrBlank()) "Orders" else name,
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            if (!description.isNullOrBlank()) this.description = description
            // No channel sound and no channel vibration: the note below is the
            // only sound, which is what makes it stoppable.
            setSound(null, null)
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setBypassDnd(false)
        }
        nm.createNotificationChannel(alert)

        val ongoing = NotificationChannel(
            CHANNEL_ONGOING,
            if (name.isNullOrBlank()) "Orders awaiting action" else "$name — awaiting action",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            setSound(null, null)
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannel(ongoing)
    }

    /**
     * The whole alert: a heads-up notification, an Open action and a Stop
     * action, and at most `ring_cap` short notes over its whole life.
     */
    fun show(ctx: Context, a: JSONObject) {
        // A synthetic alert has no row this phone can open. It is never shown
        // and never heard — the backend already refuses to push one, and this
        // is the same refusal on the device, for an app that has not updated.
        if (a.optBoolean("is_synthetic", false)) return

        val alertId = a.optLong("alert_id", 0L)
        val id = notificationId(alertId)
        ensureChannels(ctx, a.optString("channel_name"), a.optString("channel_description"))

        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return

        val open = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("deep_link", a.optString("deep_link").ifBlank { "/admin/order-alerts" })
        }
        val openPi = PendingIntent.getActivity(
            ctx, id, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val title = a.optString("push_title", "")
        val body = a.optString("push_body", "")
        val credit = a.optString("credit_note", "")

        val b = Notification.Builder(ctx, CHANNEL_ALERT)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(if (title.isBlank()) a.optString("customer") else title)
            .setContentText(if (body.isBlank()) a.optString("order_code") else body)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            // Never ongoing any more: a notification the user cannot swipe away
            // is the same trap as a ring they cannot stop.
            .setOngoing(false)
            // The channel is silent and this object plays the note, so Android
            // must not re-alert on an update either.
            .setOnlyAlertOnce(true)
            .setContentIntent(openPi)

        if (credit.isNotBlank()) {
            b.setStyle(Notification.BigTextStyle().bigText("$body\n$credit"))
        }

        val openLabel = a.optString("open_label")
        if (openLabel.isNotBlank()) {
            b.addAction(
                Notification.Action.Builder(
                    null as android.graphics.drawable.Icon?,
                    openLabel,
                    openPi,
                ).build(),
            )
        }

        // CMD #2015 item 5 — Stop. Always present, always the backend's word.
        val stopLabel = a.optString("stop_label")
        if (stopLabel.isNotBlank()) {
            val stop = Intent(ctx, OrderAlertActionReceiver::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_ACTION, "stop")
                putExtra(EXTRA_ALERT_ID, alertId)
                putExtra(EXTRA_NOTIF_ID, id)
                putExtra(EXTRA_TOKEN, a.optString("stop_token"))
                putExtra(EXTRA_URL, a.optString("stop_url"))
            }
            val stopPi = PendingIntent.getBroadcast(
                ctx, id + 1, stop,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            b.addAction(
                Notification.Action.Builder(
                    null as android.graphics.drawable.Icon?,
                    stopLabel,
                    stopPi,
                ).build(),
            )
        }

        // No full-screen intent and no PRIORITY_MAX: a lock-screen takeover is
        // the alarm/call treatment this change removes. IMPORTANCE_HIGH still
        // gives the alert a heads-up banner.
        b.setPriority(Notification.PRIORITY_DEFAULT)

        nm.notify(id, b.build())
        rememberLive(ctx, alertId)

        val cap = a.optInt("ring_cap", 3)
        val silent = a.optBoolean("silent", false) || a.optBoolean("mute_all", false)
        if (!silent && ringsUsed(ctx, alertId) < cap && !isStopped(ctx, alertId)) {
            if (startRinging(ctx, a.optInt("ring_seconds", 10))) {
                prefs(ctx).edit().putInt(KEY_RINGS + alertId, ringsUsed(ctx, alertId) + 1).apply()
            }
        }
        showOngoing(ctx, a)
    }

    /** The sticky "N orders awaiting" line. */
    fun showOngoing(ctx: Context, a: JSONObject) {
        val count = a.optInt("pending_count", 0)
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (count <= 0) {
            nm.cancel(ONGOING_ID)
            return
        }
        ensureChannels(ctx, a.optString("channel_name"), a.optString("channel_description"))
        val open = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("deep_link", "/admin/order-alerts")
        }
        val pi = PendingIntent.getActivity(
            ctx, ONGOING_ID, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(ctx, CHANNEL_ONGOING)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(a.optString("ongoing_title"))
            .setContentText(a.optString("ongoing_body"))
            .setOngoing(false)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(pi)
            .setNumber(count)
            .build()
        nm.notify(ONGOING_ID, n)
    }

    // ── The sound ─────────────────────────────────────────────────────────

    /**
     * True when the phone is allowed to make a sound right now: not silent,
     * not vibrate-only, not under Do Not Disturb, and the ring volume is not
     * zero. Every one of these was bypassed before this change.
     */
    fun soundAllowed(ctx: Context): Boolean {
        val am = ctx.getSystemService(AudioManager::class.java) ?: return false
        if (am.ringerMode != AudioManager.RINGER_MODE_NORMAL) return false
        if (am.getStreamVolume(AudioManager.STREAM_RING) <= 0) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            val filter = nm?.currentInterruptionFilter ?: NotificationManager.INTERRUPTION_FILTER_ALL
            if (filter != NotificationManager.INTERRUPTION_FILTER_ALL &&
                filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
            ) {
                return false
            }
        }
        return true
    }

    /** ONE note. Never looped, never longer than MAX_RING_MS. */
    @Synchronized
    fun startRinging(ctx: Context, seconds: Int): Boolean {
        stopRinging(ctx)
        if (!soundAllowed(ctx)) return false
        return try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE) ?: return false
            val app = ctx.applicationContext
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        // STREAM_RING: silent mode, vibrate mode and the volume
                        // keys all apply to it, which is the entire point.
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(app, uri)
                isLooping = false
                setOnCompletionListener { stopRinging(app) }
                prepare()
                start()
            }
            silencer = SilenceWatcher.start(app)
            val ms = (seconds.coerceIn(1, 20) * 1000L).coerceAtMost(MAX_RING_MS)
            handler.postDelayed({ stopRinging(app) }, ms)
            true
        } catch (e: Exception) {
            Log.w(TAG, "ring failed: ${e.message}")
            stopRinging(ctx)
            false
        }
    }

    @Synchronized
    fun stopRinging(ctx: Context) {
        handler.removeCallbacksAndMessages(null)
        try {
            player?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (_: Exception) {
        }
        player = null
        silencer?.let { it.stop(ctx.applicationContext) }
        silencer = null
    }

    // ── What this device believes is live ─────────────────────────────────

    private fun ringsUsed(ctx: Context, alertId: Long): Int =
        prefs(ctx).getInt(KEY_RINGS + alertId, 0)

    private fun isStopped(ctx: Context, alertId: Long): Boolean =
        prefs(ctx).getBoolean(KEY_STOPPED + alertId, false)

    fun markStopped(ctx: Context, alertId: Long) {
        prefs(ctx).edit().putBoolean(KEY_STOPPED + alertId, true).apply()
    }

    private fun liveIds(ctx: Context): MutableSet<String> =
        HashSet(prefs(ctx).getStringSet(KEY_LIVE, emptySet()) ?: emptySet())

    private fun rememberLive(ctx: Context, alertId: Long) {
        val s = liveIds(ctx)
        s.add(alertId.toString())
        prefs(ctx).edit().putStringSet(KEY_LIVE, s).apply()
    }

    /**
     * CMD #2015 item 1 — the server is the only authority on what exists.
     * Anything this phone is showing that the server did not list is cancelled,
     * and when the list is empty every sound stops. Called on app start and on
     * every foreground.
     */
    fun reconcile(ctx: Context, serverIds: Set<Long>, muteAll: Boolean) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val known = liveIds(ctx)
        val keep = HashSet<String>()
        val ed = prefs(ctx).edit()
        for (raw in known) {
            val id = raw.toLongOrNull() ?: continue
            if (serverIds.contains(id)) {
                keep.add(raw)
            } else {
                nm?.cancel(notificationId(id))
                ed.remove(KEY_RINGS + id).remove(KEY_STOPPED + id)
            }
        }
        // A notification this phone never recorded (an old build, a restored
        // backup, the synthetic alert that started all this) is still ours to
        // clear: sweep the whole id range the scheme can produce.
        if (serverIds.isEmpty()) {
            for (i in 0 until 800) nm?.cancel(306_100 + i)
            nm?.cancel(ONGOING_ID)
            keep.clear()
        }
        ed.putStringSet(KEY_LIVE, keep).apply()
        if (serverIds.isEmpty() || muteAll) stopRinging(ctx)
    }

    /** POSTs the one-shot token to the public action function. */
    fun postAction(url: String, token: String, action: String): Boolean {
        return try {
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 12_000
                readTimeout = 12_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
            OutputStreamWriter(conn.outputStream).use {
                it.write(JSONObject().put("token", token).put("action", action).toString())
            }
            val code = conn.responseCode
            conn.disconnect()
            code in 200..299
        } catch (e: Exception) {
            Log.w(TAG, "action post failed: ${e.message}")
            false
        }
    }
}

/**
 * CMD #2015 item 4 — the volume keys and the ringer switch, live.
 *
 * A volume key press broadcasts VOLUME_CHANGED_ACTION and a switch to silent
 * or vibrate broadcasts RINGER_MODE_CHANGED_ACTION. Either one stops the note
 * mid-play, which is what "volume-down silences it instantly" means. The
 * receiver exists only while something is actually playing.
 */
class SilenceWatcher private constructor() : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        OrderAlert.stopRinging(context.applicationContext)
    }

    fun stop(ctx: Context) {
        try {
            ctx.unregisterReceiver(this)
        } catch (_: Throwable) {
        }
    }

    companion object {
        fun start(ctx: Context): SilenceWatcher {
            val w = SilenceWatcher()
            val f = IntentFilter().apply {
                addAction(AudioManager.RINGER_MODE_CHANGED_ACTION)
                addAction("android.media.VOLUME_CHANGED_ACTION")
                addAction(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
            }
            try {
                if (Build.VERSION.SDK_INT >= 33) {
                    ctx.registerReceiver(w, f, Context.RECEIVER_EXPORTED)
                } else {
                    @Suppress("UnspecifiedRegisterReceiverFlag")
                    ctx.registerReceiver(w, f)
                }
            } catch (_: Throwable) {
            }
            return w
        }
    }
}

/**
 * The notification's Stop button. It kills the sound and the notification on
 * the spot, marks the alert permanently silent on this device, and tells the
 * server off the main thread. The order itself is untouched — a decision is
 * still taken on the order screen.
 */
class OrderAlertActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val action = intent.getStringExtra(OrderAlert.EXTRA_ACTION) ?: "stop"
        val notifId = intent.getIntExtra(OrderAlert.EXTRA_NOTIF_ID, 0)
        val alertId = intent.getLongExtra(OrderAlert.EXTRA_ALERT_ID, 0L)

        OrderAlert.stopRinging(app)
        val nm = app.getSystemService(NotificationManager::class.java)
        if (notifId != 0) nm?.cancel(notifId)
        if (alertId != 0L) OrderAlert.markStopped(app, alertId)

        val token = intent.getStringExtra(OrderAlert.EXTRA_TOKEN) ?: ""
        val url = intent.getStringExtra(OrderAlert.EXTRA_URL) ?: ""
        if (token.isBlank() || url.isBlank()) return

        val pending = goAsync()
        Thread {
            try {
                OrderAlert.postAction(url, token, action)
            } finally {
                OrderAlert.stopRinging(app)
                pending.finish()
            }
        }.start()
    }
}

/**
 * Data-only messages land here even when the app is backgrounded or dead.
 * Anything that is not an order alert is left to the ordinary Flutter path.
 */
class MediboMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        if (data["type"] != "order_alert") {
            super.onMessageReceived(message)
            return
        }
        try {
            val a = JSONObject(data["alert"] ?: "{}")
            if (a.optString("push_title").isBlank()) {
                a.put("push_title", message.notification?.title ?: "")
            }
            if (a.optString("push_body").isBlank()) {
                a.put("push_body", message.notification?.body ?: "")
            }
            OrderAlert.show(applicationContext, a)
        } catch (e: Exception) {
            Log.w("OrderAlert", "bad alert payload: ${e.message}")
        }
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
    }
}
