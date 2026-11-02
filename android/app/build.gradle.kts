import java.net.URI
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Host of the web app, taken from the same `--dart-define=APP_URL=...` lib/main.dart reads (and the
// same default), so the App Link intent-filter in AndroidManifest.xml always matches the loaded site.
val defaultAppUrl = "https://earlobe-neutron-pushchair.ngrok-free.dev"
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.filter { it.isNotBlank() }
        ?.associate {
            val pair = String(Base64.getDecoder().decode(it)).split("=", limit = 2)
            pair[0] to pair.getOrElse(1) { "" }
        }
        ?: emptyMap()
val appLinkHost: String = URI(dartDefines["APP_URL"] ?: defaultAppUrl).host

android {
    namespace = "com.mncgroup.digital_settlement_webview"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mncgroup.digital_settlement_webview"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLinkHost"] = appLinkHost
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
