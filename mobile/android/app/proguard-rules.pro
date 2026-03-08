# Flutter wrapper
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Google Sign-In / GMS
-keep class com.google.android.gms.** { *; }

# Firebase Crashlytics — preserve stack traces
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception

# Play Core (deferred components) — not used but referenced by Flutter engine
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

