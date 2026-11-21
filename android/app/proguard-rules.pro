# ML Kit text recognition: optional script models that are not bundled.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Keep ML Kit / Firebase classes used through reflection.
-keep class com.google.mlkit.** { *; }
-keep class com.google_mlkit_** { *; }
-keep class com.google.firebase.** { *; }

# Flutter plugins called from native code.
-keep class io.flutter.plugins.** { *; }

# SMS plugin + our native activity (method channels).
-keep class com.shounakmulay.telephony.** { *; }
-keep class com.example.safety_guardian.** { *; }
