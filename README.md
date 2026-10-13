# Aurelia PMS Android APK

Flutter/WebView Android wrapper for the supplied Aurelia PMS HTML application.

See [CHECKLIST.md](CHECKLIST.md) for the repository, CI build, app feature, file export, permission, and device-test checklist. Items remain unchecked until they are verified; a successful build alone does not prove app behavior.

## Hotel timezone

Aurelia PMS is configured to use the IANA timezone `Asia/Kolkata` (India Standard Time, UTC+05:30) for the HTML app's date/time display and India-local date defaults. This does not change the Android device's system timezone. Verify date-only booking boundaries and exports on a real device before relying on them for financial or occupancy reporting.

## Android security hardening

The build workflow configures:

- Android Network Security Config with cleartext HTTP disabled and system certificate trust anchors only.
- Android app backup and device-transfer backup disabled.
- R8 code shrinking/optimization for the Android release build.
- Dart AOT obfuscation with split debug symbols.
- APK signature verification after the release build.
- Keystore-backed encrypted storage through `flutter_secure_storage` for native secrets. This does not automatically encrypt HTML WebView `localStorage` or the PMS records stored there.
- Minimal native file selection support for the HTML app's upload controls.

Android application sandboxing, SELinux enforcement, ART managed execution, and Google Play Protect are Android platform features; the app does not replace or reimplement them. Play Protect is managed by Google Play services / the Android device, not toggled by an APK build setting.

## Production release signing

For a persistent, updateable production APK, configure these GitHub Actions repository secrets:

- `ANDROID_KEYSTORE_BASE64`: base64-encoded Java keystore file.
- `ANDROID_KEYSTORE_PASSWORD`: keystore password.
- `ANDROID_KEY_ALIAS`: signing key alias.
- `ANDROID_KEY_PASSWORD`: signing key password.

Without all four secrets, CI uses the temporary debug key so a test APK can still be built. That APK is not suitable for production distribution or reliable future app updates. Keep the keystore and passwords private and backed up securely.

## Build

Open the GitHub Actions tab and download `aurelia-pms-release-apk` from a successful run. Confirm the run's signature verification step passed. Test QR upload, PMS workflows, and saved-data behavior on a real Android device before production use.

## Demo data and financial reports

Fresh installs start with no sample guests, bookings, reservations, expenses, or sample stock balances, so demo revenue and expenses do not inflate financial reports. Settings includes **Remove demo entries**, which removes only known built-in sample records and matching sample stock-migration rows; unrelated guest records, real transactions, and financial data are preserved.
