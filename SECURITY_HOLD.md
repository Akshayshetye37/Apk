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

## Known limitations at the time this hold was added

- PMS records are currently stored in WebView `localStorage`; native secure storage does not encrypt that store.
- Local JSON backup exports are plaintext and may contain guest/payment data. Import validation reduces malformed-input and prototype-pollution risk, but does not provide encryption or cryptographic authenticity.
- Google Drive Settings controls are not connected to a complete native backup service.
- The screenshot-reported print/export path uses `window.open()`, which is not reliable in Android WebView and needs a native-supported flow plus physical-device testing.
- Static security checks and CI compilation are not penetration tests or device validation.
