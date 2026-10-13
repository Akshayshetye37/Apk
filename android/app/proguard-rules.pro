# Keep Flutter embedding and plugin entry points safe under R8.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
# Flutter references deferred-component APIs not used by this app.
-dontwarn com.google.android.play.core.**
