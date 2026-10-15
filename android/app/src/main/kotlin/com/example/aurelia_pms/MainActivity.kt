package com.example.aurelia_pms

import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Screenshots are allowed for operational troubleshooting at the operator's request.
        // Staff must avoid capturing guest identity documents or other sensitive PMS screens.
    }
}
