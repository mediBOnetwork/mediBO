# R8/ProGuard keep rules for the minified release build.
# Flutter's Gradle plugin already keeps the engine + embedding; these cover the
# native plugins in this app that R8 fullMode is known to over-strip or warn on.

# Flutter engine / embedding (belt-and-braces).
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Flutter references Play Core (deferred components) even when unused — R8 fullMode
# fails the build on the missing classes unless told to ignore them.
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

# mobile_scanner → ML Kit barcode: reflection-loaded model classes.
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# google_maps_flutter native view.
-keep class com.google.android.libraries.maps.** { *; }

# record / audioplayers / printing use standard AAR consumer rules; nothing extra.

# ── CHANGE #275 — Google sign-in on the minified release build ───────────────
# google_sign_in 7.x on Android does NOT use play-services-auth's old
# GoogleSignInClient: it goes through androidx.credentials (Credential Manager)
# plus com.google.android.libraries.identity.googleid. Neither package was
# covered by any rule above — `-keep class com.google.android.gms.**` does not
# reach either of them — and both are reached REFLECTIVELY:
# CredentialProviderFactory loads androidx.credentials.playservices.
# CredentialProviderPlayServicesImpl by name, and the googleid credential is
# rebuilt from a Bundle. R8 fullMode over-strips exactly this shape, and the
# failure it produces (no provider -> the sheet closes itself) is reported as a
# CANCELLATION, which is indistinguishable from the user saying no.
-keep class androidx.credentials.** { *; }
-keep interface androidx.credentials.** { *; }
-dontwarn androidx.credentials.**
-keep class androidx.credentials.playservices.** { *; }
-keep class com.google.android.libraries.identity.googleid.** { *; }
-dontwarn com.google.android.libraries.identity.googleid.**
-keep class com.google.android.gms.auth.api.identity.** { *; }

# The sign-in diagnostics channel is instantiated from MainActivity only, but
# keep it explicitly so a stripped diagnostic can never be mistaken for a
# stripped sign-in.
-keep class in.medibo.app.SignInDiag { *; }
