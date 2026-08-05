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
