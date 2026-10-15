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

**The release workflow fails closed if any required secret is missing or invalid; it never falls back to debug signing.** Before a release, add all four values under GitHub repository Settings → Secrets and variables → Actions → New repository secret. Generate/store the keystore outside the repository, Base64-encode the keystore bytes for `ANDROID_KEYSTORE_BASE64`, and set the matching store password, key alias, and key password. Use a trusted offline backup of the keystore and restrict access to repository secrets. Never commit the keystore or print secret values in logs. The workflow validates the keystore/alias and compares the APK signer certificate fingerprint with the configured keystore certificate.

**Rotation:** do not casually replace the signing key for an existing app; Android updates generally need the same signing identity unless a supported app-signing key upgrade is configured. Preserve the current keystore and credentials in secure offline storage, document the certificate fingerprint, and plan any key upgrade through the applicable distribution channel before rotating secrets. Replacing repository secrets alone does not migrate already-installed apps to a new signing identity.

## Build

Open the GitHub Actions tab and download `aurelia-pms-release-apk` from a successful run. Confirm the run's signature verification step passed. Test QR upload, PMS workflows, and saved-data behavior on a real Android device before production use.

## Demo data and financial reports

Fresh installs start with no sample guests, bookings, reservations, expenses, or sample stock balances, so demo revenue and expenses do not inflate financial reports. Settings includes **Remove demo entries**, which removes only known built-in sample records and matching sample stock-migration rows; unrelated guest records, real transactions, and financial data are preserved.


## Security status and limitations

- Invoice payment QR codes are generated locally in the Android app. The invoice QR payload is not sent to an external QR-generation service.
- **Android data at rest:** this branch replaces authoritative WebView `localStorage` writes with AES-256-GCM encrypted snapshots in app-private storage. The encryption key is held in Android-backed secure storage. Existing localStorage records are migrated on first use and removed only after encrypted persistence acknowledges success. This migration and recovery flow still needs physical-device testing before release.
- **Screen capture:** Android `FLAG_SECURE` is enabled to block screenshots and recent-app previews of PMS records.
- **App lock:** first launch requires creation of a 6–12 digit PIN. PIN verification uses salted PBKDF2-HMAC-SHA256, a five-attempt limit followed by a five-minute lockout, and a lock on app backgrounding. Android device authentication is offered where supported. This is a local device access gate, not server-side authentication.
- **Android backup export:** backups are encrypted with a user-provided passphrase using PBKDF2-HMAC-SHA256 and AES-256-GCM. The passphrase is not stored by the app and is required to restore on another device. Keep it safe; losing it makes that backup unrecoverable. Browser-preview exports remain plaintext and display a warning.
- **Backup import:** validates application/version, required guest/room/booking lists, section types, unsafe property names, nesting depth, item count, and size. Encrypted backup restoration validates before replacing data and retains an encrypted recovery snapshot. Legacy plaintext JSON imports remain supported with a warning.
- HTML-generated CSV/PDF/blob exports are handed to a narrowly scoped native share handler. It validates request type, size, MIME type, and filename; physical-device export and print testing is still required.
- **Google Drive:** cloud upload is intentionally disabled in this Android build because the existing path uploaded plaintext JSON and lacked verified encrypted recovery. A complete OAuth-backed, encrypted, versioned upload/restore service is still not implemented. Settings controls should not be treated as evidence of a successful remote backup.
- **Remote JavaScript libraries:** the Android content-security policy blocks remote script execution while the JavaScript bridge is exposed. OCR and the dynamically loaded jsPDF engine are disabled on Android until their libraries are bundled and verified locally. Do not remove this restriction merely to make those features work.
- Direct Flutter dependencies are pinned. `pubspec.lock` is generated in CI for review but still needs to be committed to make dependency resolution reproducible.
- CI tests and static checks are guardrails, not a penetration test. Do not use real guest/payment data until the security hold is cleared after device testing and independent review.
