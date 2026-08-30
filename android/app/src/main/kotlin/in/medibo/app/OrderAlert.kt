package `in`.medibo.app

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * CHANGE #306 — the Zomato-style ring for an UNPAID order.
 *
 * Everything visible here is a string the backend already rendered and put in
 * the `alert` blob (order_alert_push): the title, the body, both button
 * captions, the channel's own name and description, the sticky line. This file
 * decides nothing about wording or money — it decides where Android puts them.
 *
 * Why a data-only message: a message carrying a `notification` block is drawn
 * by the system and never reaches onMessageReceived while the app is
 * backgrounded, so it could never raise a full-screen intent. push-send sends
 * alerts data-only for exactly this reason.
 */
object OrderAlert {
    const val CHANNEL_ALERT = "medibo_order_alert"
    const val CHANNEL_ONGOING = "medibo_order_ongoing"
    const val ONGOING_ID = 306_000
    private const val TAG = "OrderAlert"

    const val EXTRA_TOKEN = "oa_token"
    const val EXTRA_ACTION = "oa_action"
    const val EXTRA_URL = "oa_url"
    const val EXTRA_NOTIF_ID = "oa_notif_id"

    private var player: MediaPlayer? = null
    private val handler = Handler(Looper.getMainLooper())

    fun notificationId(alertId: Long): Int = (306_100 + (alertId % 800)).toInt()

    /** Channels are created early and idempotently: at boot and on every alert. */
    fun ensureChannels(ctx: Context, name: String?, description: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return

        val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        val alert = NotificationChannel(
            CHANNEL_ALERT,
            if (name.isNullOrBlank()) "Order alerts" else name,
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            if (!description.isNullOrBlank()) this.description = description
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 700, 400, 700, 400, 700)
            setSound(sound, attrs)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setBypassDnd(true)
        }
        nm.createNotificationChannel(alert)

        // The sticky "N orders awaiting" line is a reminder, not a second ring.
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

    /** The whole alert: full-screen intent, Accept / Reject, and the ringing. */
    fun show(ctx: Context, a: JSONObject) {
        val alertId = a.optLong("alert_id", 0L)
        val id = notificationId(alertId)
        ensureChannels(ctx, a.optString("channel_name"), a.optString("channel_description"))

        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        val token = a.optString("action_token")
        val url = a.optString("action_url")

        val open = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("deep_link", "/admin/order-alerts")
        }
        val openPi = PendingIntent.getActivity(
            ctx, id, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        fun actionPi(action: String, rq: Int): PendingIntent {
            val i = Intent(ctx, OrderAlertActionReceiver::class.java).apply {
                this.action = "in.medibo.app.ORDER_ALERT_$action"
                putExtra(EXTRA_TOKEN, token)
                putExtra(EXTRA_ACTION, action.lowercase())
                putExtra(EXTRA_URL, url)
                putExtra(EXTRA_NOTIF_ID, id)
            }
            return PendingIntent.getBroadcast(
                ctx, rq, i,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val title = a.optString("push_title", "")
        val body = a.optString("push_body", "")
        val credit = a.optString("credit_note", "")

        val b = Notification.Builder(ctx, CHANNEL_ALERT)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(if (title.isBlank()) a.optString("customer") else title)
            .setContentText(if (body.isBlank()) a.optString("order_code") else body)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(false)
            .setOngoing(true)
            .setContentIntent(openPi)

        if (credit.isNotBlank()) {
            b.setStyle(Notification.BigTextStyle().bigText("$body\n$credit"))
        }

        // Accept is offered only when the backend says it may be: an
        // over-limit customer's order cannot be accepted from the lock screen
        // any more than it can from the app.
        if (token.isNotBlank() && url.isNotBlank()) {
            if (!a.optBoolean("credit_blocked", false)) {
                b.addAction(
                    Notification.Action.Builder(
                        null, a.optString("accept_label", "Accept"), actionPi("ACCEPT", id * 2),
                    ).build(),
                )
            }
            b.addAction(
                Notification.Action.Builder(
                    null, a.optString("reject_label", "Reject"), actionPi("REJECT", id * 2 + 1),
                ).build(),
            )
        }

        // Over the lock screen. On Android 14+ USE_FULL_SCREEN_INTENT is only
        // granted outright to calling/alarm apps; where it is not, Android
        // degrades this to a heads-up notification with the same buttons
        // rather than dropping it — so the alert is never lost, it is at worst
        // less loud.
        if (a.optBoolean("full_screen", true)) {
            val km = ctx.getSystemService(KeyguardManager::class.java)
            b.setFullScreenIntent(openPi, true)
            if (km?.isKeyguardLocked == true) b.setPriority(Notification.PRIORITY_MAX)
        }

        nm.notify(id, b.build())
        startRinging(ctx, a.optInt("ring_seconds", 120))
        showOngoing(ctx, a)
    }

    /** The sticky "N orders awaiting" line — non-dismissable until all clear. */
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
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(pi)
            .setNumber(count)
            .build()
        nm.notify(ONGOING_ID, n)
    }

    /** Keeps ringing until actioned — or until the backend's own cap. */
    @Synchronized
    fun startRinging(ctx: Context, seconds: Int) {
        stopRinging(ctx)
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION) ?: return
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(ctx, uri)
                isLooping = true
                prepare()
                start()
            }
            vibrate(ctx)
            handler.postDelayed({ stopRinging(ctx) }, seconds.coerceIn(10, 600) * 1000L)
        } catch (e: Exception) {
            Log.w(TAG, "ring failed: ${e.message}")
        }
    }

    @Synchronized
    fun stopRinging(ctx: Context) {
        try {
            player?.let { if (it.isPlaying) it.stop(); it.release() }
        } catch (_: Exception) {
        }
        player = null
        try {
            vibrator(ctx)?.cancel()
        } catch (_: Exception) {
        }
    }

    private fun vibrator(ctx: Context): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (ctx.getSystemService(VibratorManager::class.java))?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }

    private fun vibrate(ctx: Context) {
        val v = vibrator(ctx) ?: return
        val pattern = longArrayOf(0, 700, 400, 700, 400, 700)
        try {
            v.vibrate(VibrationEffect.createWaveform(pattern, 0))
        } catch (_: Exception) {
        }
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
 * The lock-screen buttons. It stops the ringing immediately (the tap is the
 * decision), clears this alert's notification, and posts the token off the
 * main thread. The backend is the authority on what the action did.
 */
class OrderAlertActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val token = intent.getStringExtra(OrderAlert.EXTRA_TOKEN) ?: return
        val action = intent.getStringExtra(OrderAlert.EXTRA_ACTION) ?: return
        val url = intent.getStringExtra(OrderAlert.EXTRA_URL) ?: return
        val notifId = intent.getIntExtra(OrderAlert.EXTRA_NOTIF_ID, 0)

        OrderAlert.stopRinging(context)
        val nm = context.getSystemService(NotificationManager::class.java)
        if (notifId != 0) nm?.cancel(notifId)

        val pending = goAsync()
        val app = context.applicationContext
        Thread {
            try {
                OrderAlert.postAction(url, token, action)
            } finally {
                // The sticky count is the backend's, refreshed by the next
                // push or by the app; clearing it here would lie when other
                // orders are still waiting.
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
            // A data-only message carries no notification block at all: the
            // rendered title and body are inside the blob, put there by
            // order_alert_push(). The notification block is only a fallback
            // for a message that happens to have one.
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
