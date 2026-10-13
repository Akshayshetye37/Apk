package com.example.aurelia_pms

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.spec.PBEKeySpec
import javax.crypto.SecretKeyFactory

class MainActivity : FlutterActivity() {
    private val securityChannel = "com.example.aurelia_pms/security"
    private val deviceAuthRequestCode = 4109
    private var pendingDeviceAuth: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, securityChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "derivePinHash" -> try {
                    val pin = call.argument<String>("pin")
                    val salt = call.argument<String>("salt")
                    val iterations = call.argument<Int>("iterations") ?: 120000
                    if (pin == null || !pin.matches(Regex("\\d{4,8}")) || salt.isNullOrBlank() || iterations !in 100000..200000) {
                        result.error("invalid_pin_input", "Invalid PIN derivation input", null)
                    } else {
                        val spec = PBEKeySpec(pin.toCharArray(), salt.toByteArray(Charsets.UTF_8), iterations, 256)
                        val bytes = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
                        spec.clearPassword()
                        result.success(bytes.joinToString("") { "%02x".format(it) })
                    }
                } catch (_: Exception) { result.error("pin_derivation_failed", "Could not derive PIN verifier", null) }
                "authenticateDevice" -> {
                    if (pendingDeviceAuth != null) { result.error("auth_in_progress", "Device authentication already in progress", null); return@setMethodCallHandler }
                    val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                    if (!keyguard.isDeviceSecure) { result.success(false) } else {
                        @Suppress("DEPRECATION")
                        val intent = keyguard.createConfirmDeviceCredentialIntent("Unlock Aurelia PMS", "Confirm your screen lock to access hotel records")
                        if (intent == null) {
                            result.success(false)
                        } else {
                            pendingDeviceAuth = result
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, deviceAuthRequestCode)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Used for system device-credential confirmation compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == deviceAuthRequestCode) { val callback = pendingDeviceAuth; pendingDeviceAuth = null; callback?.success(resultCode == RESULT_OK) }
    }
}