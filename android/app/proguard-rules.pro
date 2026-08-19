# ─── Flutter ──────────────────────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# ─── Flutter Background Service ───────────────────────────────────────────────
-keep class id.flutter.flutter_background_service.** { *; }
-dontwarn id.flutter.flutter_background_service.**

# ─── Flutter Local Notifications ──────────────────────────────────────────────
-keep class com.dexterous.** { *; }

# ─── Flutter Secure Storage ───────────────────────────────────────────────────
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-dontwarn com.it_nomads.fluttersecurestorage.**

# ─── Veepoo SDK (local AARs) ──────────────────────────────────────────────────
-keep class com.veepoo.** { *; }
-keep class com.inuker.bluetooth.** { *; }
-keep class com.jieli.** { *; }
-keep class com.jl.** { *; }
-dontwarn com.veepoo.**
-dontwarn com.inuker.**
-dontwarn com.jieli.**

# ─── Gson (used by Veepoo SDK) ────────────────────────────────────────────────
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn sun.misc.**
-keep class com.google.gson.** { *; }
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# ─── Nordic Semiconductor (mcumgr / BLE) ──────────────────────────────────────
-keep class no.nordicsemi.** { *; }
-dontwarn no.nordicsemi.**

# ─── AndroidX / Java reflection ───────────────────────────────────────────────
-keep class androidx.security.crypto.** { *; }
-dontwarn androidx.security.crypto.**

# ─── Audio Players ────────────────────────────────────────────────────────────
-keep class xyz.luan.audioplayers.** { *; }
-dontwarn xyz.luan.audioplayers.**

# ─── Vibration ────────────────────────────────────────────────────────────────
-keep class me.codefire.vibration.** { *; }
-dontwarn me.codefire.vibration.**

# ─── Flutter TTS ──────────────────────────────────────────────────────────────
-keep class com.tundralabs.fluttertts.** { *; }
-dontwarn com.tundralabs.fluttertts.**

# ─── SqFlite ──────────────────────────────────────────────────────────────────
-keep class com.tekartik.sqflite.** { *; }
-dontwarn com.tekartik.sqflite.**

# ─── General: keep all public APIs and serializable classes ───────────────────
-keepclassmembers class * implements java.io.Serializable {
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}
