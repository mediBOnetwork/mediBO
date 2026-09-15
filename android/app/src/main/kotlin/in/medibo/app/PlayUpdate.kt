package `in`.medibo.app

import android.app.Activity
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.InstallStateUpdatedListener
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.InstallStatus
import com.google.android.play.core.install.model.UpdateAvailability
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * CMD #2028 — the Play In-App Updates bridge behind the floating update pill.
 *
 * Dart never decides WHICH flow to run: `app_update_bar()` sends `flow`
 * ('flexible' | 'immediate') and this seam simply starts the one it was told to
 * start. Everything here is mechanics — launching Play's own dialog, watching
 * the download, and applying it.
 *
 * FLEXIBLE is the default: Play downloads in the background, the customer keeps
 * shopping, and the moment the bytes are on the device we call
 * `completeUpdate()`, which restarts the app into the new build. IMMEDIATE is
 * Play's blocking, full-screen flow, used only when the running versionCode is
 * below the backend's minimum — a build too old to keep taking orders.
 *
 * Nothing in here is fatal. A device with no Play Store, a sideloaded install
 * or a Play outage all answer "not available" and the web/APK paths stay
 * exactly as they were.
 */
object PlayUpdate {
    private const val CHANNEL = "in.medibo.app/play_update"
    const val REQUEST_CODE = 20280

    private var manager: AppUpdateManager? = null
    private var channel: MethodChannel? = null
    private var listener: InstallStateUpdatedListener? = null

    fun register(messenger: BinaryMessenger, activity: Activity) {
        val mgr = try {
            AppUpdateManagerFactory.create(activity.applicationContext)
        } catch (_: Throwable) {
            null
        }
        manager = mgr
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch

        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                // Is this seam usable at all? False on any device where the
                // Play update manager could not even be created.
                "available" -> result.success(mgr != null)

                // What Play itself thinks. Deliberately separate from the
                // backend's answer: the bar is raised by app_update_bar(), and
                // this only says whether Play can serve the update in-app.
                "check" -> {
                    if (mgr == null) {
                        result.success(mapOf("available" to false))
                        return@setMethodCallHandler
                    }
                    mgr.appUpdateInfo
                        .addOnSuccessListener { info ->
                            result.success(
                                mapOf(
                                    "available" to
                                        (info.updateAvailability() ==
                                            UpdateAvailability.UPDATE_AVAILABLE),
                                    "inProgress" to
                                        (info.updateAvailability() ==
                                            UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS),
                                    "versionCode" to info.availableVersionCode(),
                                    "flexible" to
                                        info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE),
                                    "immediate" to
                                        info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE),
                                    "downloaded" to
                                        (info.installStatus() == InstallStatus.DOWNLOADED)
                                )
                            )
                        }
                        .addOnFailureListener {
                            result.success(mapOf("available" to false))
                        }
                }

                // Start the flow the BACKEND chose. Returns false when Play
                // cannot run it, so Dart can fall back to opening the listing.
                "start" -> {
                    val immediate = call.argument<String>("flow") == "immediate"
                    if (mgr == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    mgr.appUpdateInfo
                        .addOnSuccessListener { info ->
                            val type =
                                if (immediate) AppUpdateType.IMMEDIATE else AppUpdateType.FLEXIBLE
                            val ready =
                                info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE ||
                                    info.updateAvailability() ==
                                    UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS
                            if (!ready || !info.isUpdateTypeAllowed(type)) {
                                result.success(false)
                                return@addOnSuccessListener
                            }
                            // Already downloaded from an earlier flexible run:
                            // nothing to start, just apply it.
                            if (!immediate && info.installStatus() == InstallStatus.DOWNLOADED) {
                                mgr.completeUpdate()
                                result.success(true)
                                return@addOnSuccessListener
                            }
                            if (!immediate) attachListener(mgr)
                            try {
                                mgr.startUpdateFlowForResult(
                                    info,
                                    AppUpdateOptions.newBuilder(type).build(),
                                    activity,
                                    REQUEST_CODE
                                )
                                result.success(true)
                            } catch (_: Throwable) {
                                result.success(false)
                            }
                        }
                        .addOnFailureListener { result.success(false) }
                }

                // Apply a download that is already on the device (also called
                // on resume, for a flexible download that finished in the
                // background while the app was away).
                "complete" -> {
                    if (mgr == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        mgr.completeUpdate()
                        result.success(true)
                    } catch (_: Throwable) {
                        result.success(false)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Watch a flexible download and apply it the instant it lands — the spec's
     * "on download complete, apply and restart". Dart is told first so the pill
     * can swap to its restarting label before the process goes away.
     */
    private fun attachListener(mgr: AppUpdateManager) {
        if (listener != null) return
        val l = InstallStateUpdatedListener { state ->
            if (state.installStatus() == InstallStatus.DOWNLOADED) {
                try {
                    channel?.invokeMethod("downloaded", null)
                } catch (_: Throwable) {
                }
                try {
                    mgr.completeUpdate()
                } catch (_: Throwable) {
                }
                detachListener(mgr)
            } else if (state.installStatus() == InstallStatus.FAILED ||
                state.installStatus() == InstallStatus.CANCELED
            ) {
                try {
                    channel?.invokeMethod("failed", null)
                } catch (_: Throwable) {
                }
                detachListener(mgr)
            }
        }
        listener = l
        try {
            mgr.registerListener(l)
        } catch (_: Throwable) {
            listener = null
        }
    }

    private fun detachListener(mgr: AppUpdateManager) {
        val l = listener ?: return
        listener = null
        try {
            mgr.unregisterListener(l)
        } catch (_: Throwable) {
        }
    }
}
