# Aurelia PMS — Critical Security Hold

**Release status: NOT APPROVED FOR PRODUCTION USE.**

Do not use this build with real guest identity documents, personally identifiable information, payment records, or other sensitive hotel data until the required controls have been implemented, independently reviewed, and verified through testing. A visible security feature or successful APK build is not proof of security.

## Release-blocking requirements

- [ ] **Authentication and access control:** enforced app lock; protected PIN verification and retry limits; session locking; Android biometric/device authentication where supported; verify sensitive screens and native operations cannot bypass access control; document offline/client-side limitations.
- [ ] **Encrypted data storage:** current implementation stores encrypted AES-GCM snapshots in app-private storage with an Android-backed key; it is not yet a pair of independent SQLite databases. Verify migration/cleanup, recovery, key loss, reinstall, temporary/export files, and unauthorized file access on physical devices; decide whether independent hotel/restaurant databases are a release requirement before marking this complete.
- [ ] **Secure Google Drive backup and recovery:** supported least-privilege OAuth; connection/disconnection/expiry/recovery handling; durable queue; encrypted, versioned, per-device backups; resumable uploads; explicit pending/uploading/failed/confirmed states; confirm uploaded version before marking complete; prevent silent overwrites; test integrity and restore.
- [ ] **File I/O and offline behavior:** fix and device-test PDF/CSV export/print; use Android picker/save/share APIs; test offline failures, large exports, denied permissions, interruptions, and restarts without silent data loss.
- [x] **Repository/build integrity (CI lockfile enforcement):** commit `pubspec.lock`; use one authoritative Flutter project; keep signing keys and OAuth secrets out of source control; require production signing configuration for release builds. CI now rejects missing or inconsistent lockfiles. Remaining release/signing requirements are still unverified.
- [ ] **Release validation:** successful release build; install on physical Android devices; test with fictional guest/payment data; validate authentication bypass resistance, encryption, backup/restore, exports, and offline recovery; document results and obtain security review approval. CI on the current PR head passes lockfile enforcement, Flutter analysis/tests, static security checks, backup-import regression tests, and the release workflow has passed those checks plus JavaScript syntax checks and is building an unsigned debug APK.

## Acceptance criteria

The hold remains until authentication tests pass; sensitive records and backups are encrypted and verified; backup tracking, resumable uploads, and restoration work; exports, file selection, and offline behavior pass device tests; the source builds reproducibly and the signed APK is validated; and all release-blocking defects are resolved with evidence.

**Until then, use sample data only. Do not treat the app as production-secure or as the sole copy of hotel records.**

## Remediation branch status (not yet release-approved)

- This branch implements AES-256-GCM encrypted app-private PMS snapshots with an Android-backed key, a first-run PIN gate, a five-attempt lockout, background locking, and device authentication where supported. Screenshot capture is allowed by requirement; `FLAG_SECURE` is not enabled. Legacy localStorage is migrated and cleared only after encrypted save acknowledgement. The native handler and injected WebView settings hook also fail closed if code attempts to disable the native lock. These changes still need physical-device migration, recovery, and bypass testing.
- Android backup export now uses a portable passphrase-encrypted envelope with PBKDF2-HMAC-SHA256 and AES-256-GCM. The app does not store the passphrase. Browser-preview exports remain plaintext and show a warning. Legacy plaintext imports remain supported with a warning.
- Encrypted restore validates the payload before replacing the database and writes an encrypted recovery snapshot. Test wrong passphrases, tampered files, malformed data, large payloads, and storage failures.
- Direct OAuth/Drive API upload and background sync remain disabled. The passphrase-encrypted `.aurelia` backup uses Android's save-location picker and file picker for manual save/restore; if Google Drive is selected, verify the saved file exists. OAuth-backed versioning, retries, automatic upload confirmation, and physical-device restore tests remain outstanding.
- Offline OCR now uses bundled ML Kit Latin/Devanagari recognizers and has parser regression tests for common Indian IDs. Physical-device model initialization, image quality and OCR accuracy still require testing. PDF/CSV/print behavior also needs physical-device testing because window.open() paths may fail in Android WebView. The Android CSP blocks remote JavaScript; dynamic jsPDF remains disabled until bundled locally.
- `pubspec.lock` is committed and enforced by CI. Release build, signing, APK installation, and update behavior remain to be verified.
- Static checks and CI tests are not a penetration test or device validation.

**The production hold remains active until every release blocker is verified with evidence.**
