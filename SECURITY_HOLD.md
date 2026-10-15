# Aurelia PMS — Critical Security Hold

**Release status: NOT APPROVED FOR PRODUCTION USE.**

Do not use this build with real guest identity documents, personally identifiable information, payment records, or other sensitive hotel data until the required controls have been implemented, independently reviewed, and verified through testing. A visible security feature or successful APK build is not proof of security.

## Release-blocking requirements

- [ ] **Authentication and access control:** enforced app lock; protected PIN verification and retry limits; session locking; Android biometric/device authentication where supported; verify sensitive screens and native operations cannot bypass access control; document offline/client-side limitations.
- [ ] **Encrypted data storage:** replace WebView `localStorage` as authoritative sensitive storage with an encrypted local database and protected keys; encrypt backups before upload; protect temporary/export files; safely migrate existing data and remove plaintext copies only after verification; test recovery, key loss, reinstall, and unauthorized file access.
- [ ] **Secure Google Drive backup and recovery:** supported least-privilege OAuth; connection/disconnection/expiry/recovery handling; durable queue; encrypted, versioned, per-device backups; resumable uploads; explicit pending/uploading/failed/confirmed states; confirm uploaded version before marking complete; prevent silent overwrites; test integrity and restore.
- [ ] **File I/O and offline behavior:** fix and device-test PDF/CSV export/print; use Android picker/save/share APIs; test offline failures, large exports, denied permissions, interruptions, and restarts without silent data loss.
- [ ] **Repository/build integrity:** commit `pubspec.lock`; use one authoritative Flutter project; keep signing keys and OAuth secrets out of source control; require production signing configuration for release builds.
- [ ] **Release validation:** successful release build; install on physical Android devices; test with fictional guest/payment data; validate authentication bypass resistance, encryption, backup/restore, exports, and offline recovery; document results and obtain security review approval.

## Acceptance criteria

The hold remains until authentication tests pass; sensitive records and backups are encrypted and verified; backup tracking, resumable uploads, and restoration work; exports, file selection, and offline behavior pass device tests; the source builds reproducibly and the signed APK is validated; and all release-blocking defects are resolved with evidence.

**Until then, use sample data only. Do not treat the app as production-secure or as the sole copy of hotel records.**

## Remediation branch status (not yet release-approved)

- This branch implements AES-256-GCM encrypted app-private PMS snapshots with an Android-backed key, a first-run PIN gate, a five-attempt lockout, background locking, and device authentication where supported. Legacy localStorage is migrated and cleared only after encrypted save acknowledgement. These changes still need physical-device migration, recovery, and bypass testing.
- Android backup export now uses a portable passphrase-encrypted envelope with PBKDF2-HMAC-SHA256 and AES-256-GCM. The app does not store the passphrase. Browser-preview exports remain plaintext and show a warning. Legacy plaintext imports remain supported with a warning.
- Encrypted restore validates the payload before replacing the database and writes an encrypted recovery snapshot. Test wrong passphrases, tampered files, malformed data, large payloads, and storage failures.
- Google Drive Settings controls are not connected to a complete native backup service. OAuth, encrypted versioning, upload confirmation, retries, and restoration remain outstanding.
- PDF/CSV/print behavior still needs physical-device testing. The native file-sharing bridge exists, but the HTML app still contains window.open() print paths that may fail in Android WebView.
- pubspec.lock is generated in CI for review but has not yet been committed. Release build, signing, APK installation, and update behavior remain to be verified.
- Static checks and CI tests are not a penetration test or device validation.

**The production hold remains active until every release blocker is verified with evidence.**
