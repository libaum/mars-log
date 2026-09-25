package com.catchingclouds.marslog

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth.
class MainActivity : FlutterFragmentActivity() {
    private var nano: NanoChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nano = NanoChannel(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        nano?.dispose()
        nano = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
