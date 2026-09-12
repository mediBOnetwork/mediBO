package `in`.medibo.app

import android.content.Context
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * CHANGE #225 — the readiness gate in front of the ML Kit Document Scanner.
 *
 * The scanner is NOT a bundled model: it is an on-demand Play Services module.
 * When that module is missing and cannot be downloaded, Google's own activity
 * paints "Something went wrong — Try again later" and then returns
 * RESULT_CANCELED, which the Flutter plugin reports as a plain user cancel. The
 * app therefore did nothing, and the user was dead-ended on a Google error
 * screen with no way forward.
 *
 * The fix is to never launch that activity unless the module is actually there.
 * This channel answers two questions for Dart:
 *
 *   status  -> { playServices: Bool, moduleReady: Bool }
 *   install -> Bool   (deferred module install request; true == now available)
 *
 * Anything unexpected resolves to "not ready" rather than throwing, because the
 * caller's response to "not ready" is the raw camera — always a working path.
 */
object DocScanReadiness {
    private const val CHANNEL = "in.medibo.app/doc_scan"

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> status(context, result)
                "install" -> install(context, result)
                else -> result.notImplemented()
            }
        }
    }

    /** The scanner options only identify the API here; the real scan uses the plugin's own. */
    private fun scannerApi() = GmsDocumentScanning.getClient(
        GmsDocumentScannerOptions.Builder().build()
    )

    private fun playServicesOk(context: Context): Boolean = try {
        GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
    } catch (_: Throwable) {
        false
    }

    private fun status(context: Context, result: MethodChannel.Result) {
        val hasPlay = playServicesOk(context)
        if (!hasPlay) {
            result.success(mapOf("playServices" to false, "moduleReady" to false))
            return
        }
        try {
            ModuleInstall.getClient(context)
                .areModulesAvailable(scannerApi())
                .addOnSuccessListener { response ->
                    result.success(
                        mapOf(
                            "playServices" to true,
                            "moduleReady" to response.areModulesAvailable()
                        )
                    )
                }
                .addOnFailureListener {
                    // Could not even ask -> treat as not ready, never as an error.
                    result.success(mapOf("playServices" to true, "moduleReady" to false))
                }
        } catch (_: Throwable) {
            result.success(mapOf("playServices" to true, "moduleReady" to false))
        }
    }

    private fun install(context: Context, result: MethodChannel.Result) {
        if (!playServicesOk(context)) {
            result.success(false)
            return
        }
        try {
            val request = ModuleInstallRequest.newBuilder().addApi(scannerApi()).build()
            ModuleInstall.getClient(context)
                .installModules(request)
                .addOnSuccessListener { response ->
                    // Already-present counts as installed; a queued download does not,
                    // because launching before it lands is the very failure being fixed.
                    result.success(response.areModulesAlreadyInstalled())
                }
                .addOnFailureListener { result.success(false) }
        } catch (_: Throwable) {
            result.success(false)
        }
    }
}
