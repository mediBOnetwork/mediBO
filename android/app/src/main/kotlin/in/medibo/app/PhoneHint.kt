package `in`.medibo.app

import android.app.Activity
import android.content.Intent
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * CMD #2151 — the phone's own number list behind registration's WhatsApp box
 * (Google Phone Number Hint). No permission, no SMS read: Play services shows
 * the SIM numbers and hands back only the one the person taps.
 *
 * Mechanics only. The number goes back to Dart RAW; the backend's
 * custreg_contact_check cleans it (+91 / leading 0) and judges it exactly like
 * a typed one. A closed sheet, no SIM or no Play services all answer null.
 */
object PhoneHint {
    private const val CHANNEL = "medibo/phone_hint"
    const val REQUEST_CODE = 21510

    private var pending: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger, activity: Activity) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> pick(activity, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun pick(activity: Activity, result: MethodChannel.Result) {
        if (pending != null) {
            result.success(null)
            return
        }
        try {
            val request = GetPhoneNumberHintIntentRequest.builder().build()
            Identity.getSignInClient(activity)
                .getPhoneNumberHintIntent(request)
                .addOnSuccessListener { pi ->
                    try {
                        pending = result
                        activity.startIntentSenderForResult(
                            pi.intentSender, REQUEST_CODE, null, 0, 0, 0, null,
                        )
                    } catch (_: Throwable) {
                        pending = null
                        result.success(null)
                    }
                }
                .addOnFailureListener { result.success(null) }
        } catch (_: Throwable) {
            result.success(null)
        }
    }

    /** Called from MainActivity.onActivityResult; true when it was ours. */
    fun onResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val r = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            r.success(null)
            return true
        }
        try {
            r.success(Identity.getSignInClient(activity).getPhoneNumberFromIntent(data))
        } catch (_: Throwable) {
            r.success(null)
        }
        return true
    }
}
