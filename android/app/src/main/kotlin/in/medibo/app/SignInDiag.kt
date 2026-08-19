package `in`.medibo.app

import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * CHANGE #275 / #279 — the device facts that settle which certificate the
 * running build actually carries.
 *
 * Google sign-in worked on the sideloaded APK and died on the Play build. The
 * only functional difference between those artifacts is the signing
 * certificate: Play re-signs the upload with its own app-signing key, and
 * Credential Manager matches package + certificate against a registered Android
 * OAuth client. So the app reports the certificate instead of anyone guessing.
 *
 * CHANGE #279 — #275 reported exactly one fingerprint, and it read it from
 * `signingCertificateHistory`, whose FIRST element is the OLDEST certificate of
 * a rotation chain, not the certificate this APK is signed with. A device
 * reported 69:37:2B:... for builds whose APKs verify as CB:88:BD:C5:..., and
 * one number could not tell "the wrong certificate is registered" from "we read
 * the wrong certificate". Everything is reported now:
 *
 *   * signing_sha1 / signing_sha256 — the CURRENT signer (apkContentsSigners),
 *     which is what Play services matches against a registered OAuth client
 *   * signers_sha1   — every current signer, comma-separated
 *   * history_sha1   — the whole rotation history, oldest first
 *   * has_multiple_signers
 *   * install_source — the package that installed this app
 *     (com.android.vending = Play Store), or "sideload" when Android names none
 *
 * Read-only. Nothing here is a secret — a signing certificate fingerprint is
 * public information printed by `apksigner verify --print-certs` on any copy of
 * the app.
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

    /** Uppercase colon-separated digest of one certificate, e.g. `CB:88:BD:…`. */
    private fun fingerprint(sig: Signature, algorithm: String): String =
        MessageDigest.getInstance(algorithm)
            .digest(sig.toByteArray())
            .joinToString(":") { "%02X".format(it) }

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

            // Where the APK came from. com.android.vending is the Play Store;
            // a null installer is a plain sideload (adb / a downloaded file).
            out["install_source"] = try {
                @Suppress("DEPRECATION")
                val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    pm.getInstallSourceInfo(context.packageName).installingPackageName
                } else {
                    pm.getInstallerPackageName(context.packageName)
                }
                installer ?: "sideload"
            } catch (e: Throwable) {
                "sideload"
            }

            val signingInfo =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.signingInfo else null

            // apkContentsSigners is the certificate(s) THIS apk is signed with —
            // always the right answer for "is this build registered?".
            // signingCertificateHistory is the rotation proof (oldest first) and
            // is reported separately, never mistaken for the current signer.
            @Suppress("DEPRECATION")
            val current: Array<Signature>? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    signingInfo?.apkContentsSigners
                } else {
                    info.signatures
                }
            val history: Array<Signature>? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                    signingInfo?.hasMultipleSigners() == false
                ) {
                    signingInfo.signingCertificateHistory
                } else {
                    null
                }

            out["has_multiple_signers"] = signingInfo?.hasMultipleSigners() ?: false

            val signer = current?.firstOrNull() ?: history?.lastOrNull()
            if (signer != null) {
                out["signing_sha1"] = fingerprint(signer, "SHA-1")
                out["signing_sha256"] = fingerprint(signer, "SHA-256")
            }
            if (current != null && current.isNotEmpty()) {
                out["signers_sha1"] =
                    current.joinToString(", ") { fingerprint(it, "SHA-1") }
            }
            if (history != null && history.isNotEmpty()) {
                out["history_sha1"] =
                    history.joinToString(", ") { fingerprint(it, "SHA-1") }
            }
        } catch (e: Throwable) {
            // A diagnostic must never be the thing that breaks sign-in.
            out["facts_error"] = e.toString()
        }
        return out
    }
}
