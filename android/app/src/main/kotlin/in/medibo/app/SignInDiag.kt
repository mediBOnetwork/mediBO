package `in`.medibo.app

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * CHANGE #275 — the device facts that separate a sideloaded APK from the
 * Play-signed build.
 *
 * Google sign-in worked on the sideloaded APK and died silently on the Play
 * build. The ONLY functional difference between those two artifacts is the
 * signing certificate: Play re-signs the upload with its own app-signing key,
 * and Credential Manager matches package + certificate against a registered
 * Android OAuth client. Guessing which certificate a phone is running is what
 * made this bug unfixable, so the app now reports it: the running APK's
 * SHA-1, its package name and its versionCode are attached to every recorded
 * sign-in failure (auth_diag).
 *
 * Read-only. Nothing here is a secret — a signing certificate fingerprint is
 * public information printed by `apksigner verify --print-certs` on any copy
 * of the app.
 */
object SignInDiag {
    private const val CHANNEL = "in.medibo.app/signin_diag"

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceFacts" -> result.success(deviceFacts(context))
                else -> result.notImplemented()
            }
        }
    }

    private fun deviceFacts(context: Context): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        out["package_name"] = context.packageName
        out["android_sdk"] = Build.VERSION.SDK_INT
        try {
            val pm = context.packageManager
            @Suppress("DEPRECATION")
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            } else {
                pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNATURES)
            }
            out["version_name"] = info.versionName
            @Suppress("DEPRECATION")
            out["version_code"] =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode.toInt()
                else info.versionCode

            @Suppress("DEPRECATION")
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.signingInfo?.let {
                    if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory
                }
            } else {
                info.signatures
            }
            val first = signatures?.firstOrNull()
            if (first != null) {
                val digest = MessageDigest.getInstance("SHA-1").digest(first.toByteArray())
                out["signing_sha1"] = digest.joinToString(":") { "%02X".format(it) }
            }
        } catch (e: Throwable) {
            // A diagnostic must never be the thing that breaks sign-in.
            out["facts_error"] = e.toString()
        }
        return out
    }
}
