package com.example.aurelia_pms

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // PMS screens can contain guest identity and payment data. Block screenshots,
        // screen recording, and sensitive content in Android's recent-apps preview.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
}
