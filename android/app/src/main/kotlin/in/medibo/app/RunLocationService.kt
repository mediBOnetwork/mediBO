package `in`.medibo.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import org.json.JSONObject
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * CHANGE #700 — the rider's position, for the whole length of a started run.
 *
 * WHY THIS IS A SERVICE AND NOT A DART TIMER
 * The old loop was a Timer inside the rider's screen calling a browser
 * Geolocation shim. On Android that shim is the no-op native fallback, so an
 * Android rider reported NOTHING; on web it stopped the moment the tab lost
 * focus. A foreground service is the only thing Android lets keep a location
 * subscription while the app is backgrounded or the screen is locked.
 *
 * WHY IT POSTS BY ITSELF INSTEAD OF CALLING BACK INTO DART
 * Handing each fix to the Flutter engine would tie the run to the engine
 * staying alive. It does not always: Android destroys the Activity under
 * memory pressure and the engine can go with it, which is exactly the ten
 * minutes in the background this change exists to survive. So the service owns
 * the HTTP call — it holds the rider's tokens and posts straight to the
 * rider-location function, refreshing the access token itself on a 401.
 *
 * WHAT IT DOES NOT DECIDE
 * Interval, distance filter, battery-saver threshold and every word on the
 * notification arrive from delivery_live_config() and are passed in on start.
 * This class holds no policy and no copy of its own.
 *
 * Stopping is explicit: delivery_finish_run stops it. Swiping the app away
 * kills the process and with it the service — which is the intended behaviour,
 * because the customer's map is then supposed to say "last seen".
 */
class RunLocationService : Service() {

    companion object {
        private const val TAG = "RunLocationService"
        const val ACTION_START = "in.medibo.app.RUN_LOC_START"
        const val ACTION_STOP = "in.medibo.app.RUN_LOC_STOP"
        const val ACTION_TOKEN = "in.medibo.app.RUN_LOC_TOKEN"
        private const val CHANNEL_ID = "medibo_run_location"
        private const val NOTIF_ID = 7001
        private const val PREFS = "medibo_run_location"

        /** Fixes buffered while the network is unavailable. Bounded on purpose:
         *  a rider in a dead zone must not grow an unbounded backlog that then
         *  floods the server with an hour-old trail. */
        private const val QUEUE_MAX = 60
    }

    private lateinit var client: FusedLocationProviderClient
    private var callback: LocationCallback? = null
    private val io = Executors.newSingleThreadExecutor()
    private val pending = ArrayBlockingQueue<JSONObject>(QUEUE_MAX)

    // Everything below is handed in by Dart from the backend's own config.
    private var supabaseUrl = ""
    private var anonKey = ""
    @Volatile private var accessToken = ""
    @Volatile private var refreshToken = ""
    private var intervalS = 5
    private var minMoveM = 20
    private var batterySaverPct = 20
    private var batteryIntervalS = 30
    private var notifTitle = ""
    private var notifBody = ""
    private var channelName = "Delivery trip"

    private var lowPowerMode = false
    private var running = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopUpdates()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_TOKEN -> {
                // Dart pushes a refreshed session through so the service never
                // has to guess when the JWT rolled over.
                intent.getStringExtra("access_token")?.let { if (it.isNotEmpty()) accessToken = it }
                intent.getStringExtra("refresh_token")?.let { if (it.isNotEmpty()) refreshToken = it }
                persist()
                return START_STICKY
            }
        }

        if (intent != null && intent.action == ACTION_START) readConfig(intent)
        if (supabaseUrl.isEmpty()) restore()
        if (supabaseUrl.isEmpty() || accessToken.isEmpty()) {
            // Nothing to post to. Do not sit in the notification shade pretending
            // to track — stop, and let Dart start us again once it has a session.
            stopSelf()
            return START_NOT_STICKY
        }
        persist()

        startForeground(NOTIF_ID, buildNotification())
        startUpdates()
        return START_STICKY
    }

    override fun onDestroy() {
        stopUpdates()
        io.shutdownNow()
        super.onDestroy()
    }

    // ── config ───────────────────────────────────────────────────────────────

    private fun readConfig(i: Intent) {
        supabaseUrl = i.getStringExtra("supabase_url") ?: supabaseUrl
        anonKey = i.getStringExtra("anon_key") ?: anonKey
        i.getStringExtra("access_token")?.let { if (it.isNotEmpty()) accessToken = it }
        i.getStringExtra("refresh_token")?.let { if (it.isNotEmpty()) refreshToken = it }
        intervalS = i.getIntExtra("interval_s", intervalS)
        minMoveM = i.getIntExtra("min_move_m", minMoveM)
        batterySaverPct = i.getIntExtra("battery_saver_pct", batterySaverPct)
        batteryIntervalS = i.getIntExtra("battery_interval_s", batteryIntervalS)
        notifTitle = i.getStringExtra("notif_title") ?: notifTitle
        notifBody = i.getStringExtra("notif_body") ?: notifBody
        channelName = i.getStringExtra("channel_name") ?: channelName
    }

    private fun persist() {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("url", supabaseUrl).putString("anon", anonKey)
            .putString("at", accessToken).putString("rt", refreshToken)
            .putInt("iv", intervalS).putInt("mm", minMoveM)
            .putInt("bsp", batterySaverPct).putInt("bsi", batteryIntervalS)
            .putString("nt", notifTitle).putString("nb", notifBody)
            .putString("cn", channelName)
            .apply()
    }

    /** A START_STICKY restart arrives with a null intent — everything the
     *  service needs has to survive its own process. */
    private fun restore() {
        val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        supabaseUrl = p.getString("url", "") ?: ""
        anonKey = p.getString("anon", "") ?: ""
        accessToken = p.getString("at", "") ?: ""
        refreshToken = p.getString("rt", "") ?: ""
        intervalS = p.getInt("iv", intervalS)
        minMoveM = p.getInt("mm", minMoveM)
        batterySaverPct = p.getInt("bsp", batterySaverPct)
        batteryIntervalS = p.getInt("bsi", batteryIntervalS)
        notifTitle = p.getString("nt", notifTitle) ?: notifTitle
        notifBody = p.getString("nb", notifBody) ?: notifBody
        channelName = p.getString("cn", channelName) ?: channelName
    }

    // ── the notification Android requires of a foreground service ────────────

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)
        val pi = if (open == null) null else PendingIntent.getActivity(
            this, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val b = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(notifTitle)
            .setContentText(notifBody)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
        if (pi != null) b.setContentIntent(pi)
        return b.build()
    }

    // ── location ─────────────────────────────────────────────────────────────

    private fun batteryPct(): Int {
        return try {
            val i = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            if (level < 0 || scale <= 0) -1 else (level * 100 / scale)
        } catch (e: Throwable) { -1 }
    }

    /**
     * Battery-aware, and the thresholds are the backend's. Below
     * battery_saver_pct the service drops to the longer interval and asks for
     * balanced-power fixes instead of high accuracy — a rider whose phone dies
     * at 4pm reports nothing at all for the rest of the round, which is worse
     * for the customer than a coarser dot.
     */
    private fun buildRequest(): LocationRequest {
        val pct = batteryPct()
        lowPowerMode = pct in 0 until batterySaverPct
        val seconds = if (lowPowerMode) batteryIntervalS else intervalS
        val priority = if (lowPowerMode) Priority.PRIORITY_BALANCED_POWER_ACCURACY
                       else Priority.PRIORITY_HIGH_ACCURACY
        return LocationRequest.Builder(priority, TimeUnit.SECONDS.toMillis(seconds.toLong()))
            .setMinUpdateDistanceMeters(minMoveM.toFloat())
            .setMinUpdateIntervalMillis(TimeUnit.SECONDS.toMillis(seconds.toLong()))
            .setWaitForAccurateLocation(false)
            .build()
    }

    private fun startUpdates() {
        if (running) return
        client = LocationServices.getFusedLocationProviderClient(this)
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val loc = result.lastLocation ?: return
                val o = JSONObject()
                o.put("lat", loc.latitude)
                o.put("lng", loc.longitude)
                if (loc.hasBearing()) o.put("heading", loc.bearing.toDouble())
                if (loc.hasAccuracy()) o.put("accuracy", loc.accuracy.toDouble())
                val pct = batteryPct()
                if (pct >= 0) o.put("battery", pct)
                o.put("source", if (lowPowerMode) "fgs_saver" else "fgs")
                enqueue(o)
            }
        }
        callback = cb
        try {
            client.requestLocationUpdates(buildRequest(), cb, Looper.getMainLooper())
            running = true
        } catch (e: SecurityException) {
            // Permission was revoked mid-run. Nothing to report and nothing to
            // recover here: Dart re-asks when the rider next opens the app.
            Log.w(TAG, "location permission missing", e)
            stopSelf()
        }
    }

    private fun stopUpdates() {
        running = false
        try { callback?.let { client.removeLocationUpdates(it) } } catch (e: Throwable) { }
        callback = null
    }

    // ── delivery to the backend ──────────────────────────────────────────────

    private fun enqueue(o: JSONObject) {
        if (!pending.offer(o)) {
            pending.poll()      // drop the OLDEST — a stale fix is the useless one
            pending.offer(o)
        }
        io.execute { drain() }
    }

    private fun drain() {
        while (true) {
            val next = pending.peek() ?: return
            if (!post(next)) return         // still offline — keep it queued
            pending.poll()
        }
    }

    /** @return true when the fix is delivered (or is unrecoverable and should
     *  be dropped), false when it should stay queued for the next attempt. */
    private fun post(o: JSONObject): Boolean {
        val code = send(o, accessToken)
        if (code in 200..299) return true
        if (code == 401 || code == 403) {
            if (refresh()) return send(o, accessToken) in 200..299
            return false
        }
        // 4xx that is not auth: the server has judged this fix and will judge it
        // the same way forever. Dropping it is the only way out of the loop.
        if (code in 400..499) return true
        return false
    }

    private fun send(o: JSONObject, token: String): Int {
        if (token.isEmpty()) return 401
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL("$supabaseUrl/functions/v1/rider-location").openConnection() as HttpURLConnection)
            conn.requestMethod = "POST"
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("apikey", anonKey)
            conn.setRequestProperty("Authorization", "Bearer $token")
            conn.outputStream.use { it.write(o.toString().toByteArray()) }
            conn.responseCode
        } catch (e: Throwable) {
            0                                 // no network — retry later
        } finally {
            try { conn?.disconnect() } catch (e: Throwable) { }
        }
    }

    /** The run outlives the access token, so the service renews it itself
     *  rather than going silent an hour into a round. */
    private fun refresh(): Boolean {
        if (refreshToken.isEmpty() || supabaseUrl.isEmpty()) return false
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL("$supabaseUrl/auth/v1/token?grant_type=refresh_token")
                .openConnection() as HttpURLConnection)
            conn.requestMethod = "POST"
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("apikey", anonKey)
            val body = JSONObject().put("refresh_token", refreshToken).toString()
            conn.outputStream.use { it.write(body.toByteArray()) }
            if (conn.responseCode !in 200..299) return false
            val text = conn.inputStream.bufferedReader().use(BufferedReader::readText)
            val j = JSONObject(text)
            val at = j.optString("access_token", "")
            if (at.isEmpty()) return false
            accessToken = at
            j.optString("refresh_token", "").let { if (it.isNotEmpty()) refreshToken = it }
            persist()
            true
        } catch (e: Throwable) {
            false
        } finally {
            try { conn?.disconnect() } catch (e: Throwable) { }
        }
    }
}
