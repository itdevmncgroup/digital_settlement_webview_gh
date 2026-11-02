package com.mncgroup.digital_settlement_webview

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // lib/main.dart's kSettingsChannel: lets the "Aktifkan GPS" screen jump straight to the Location switch.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.mncgroup.digital_settlement_webview/settings")
            .setMethodCallHandler { call, result ->
                if (call.method == "openLocationSettings") {
                    startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
