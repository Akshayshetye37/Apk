package com.example.aurelia_pms

import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Allow Android screenshots and screen recordings. Sensitive PMS data
        // should be protected through app authentication and access controls,
        // not by disabling the device screenshot feature globally.
        super.onCreate(savedInstanceState)
    }
}
