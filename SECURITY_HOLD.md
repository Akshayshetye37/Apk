# Aurelia PMS — Release Hold

**Release status: NOT APPROVED FOR PRODUCTION USE.**

The app intentionally has no application PIN or biometric gate, at the user's request. The Settings PIN/biometric and Google Drive setup panels, plus the floating AI assistant/gateway UI, have been removed. Encrypted local backup export/restore is exposed from Import / Export. The Android runtime theme is dark brown with gold accents. Anyone who can open the app on an unlocked device may access the PMS. Use Android device-level locking and restricted device access. Do not use this configuration as a security-approved multi-user deployment.

Before production use with real guest identity documents, personally identifiable information, payment records, or other sensitive hotel data, verify the following:

- [ ] **Device access and operational controls:** restrict physical access to the device; document staff roles and who may use the app. The app does not provide its own PIN/biometric access gate.
- [ ] **Encrypted data storage:** verify encryption, key recovery/key loss behavior, migration, and that sensitive records never fall back to plaintext.
- [ ] **Backup and restore:** test encrypted export/import, wrong passphrases, tampered files, interrupted operations, and recovery without record loss. Google Drive sync is not configured; do not assume cloud backups exist.
- [ ] **Data integrity:** verify check-in/out, room assignment, restaurant POS, food-to-room billing, payments, refunds, reports, exports, and reconciliation using realistic test cases.
- [ ] **File handling:** test PDF/CSV/JSON export, file import, printing, sharing, image capture/OCR, cancellation, and permission denial on supported Android devices.
- [ ] **Device lifecycle:** test force-stop, process death, low storage, offline operation, app upgrade, reboot, and reinstall behavior without losing records.
- [ ] **Production identity and signing:** confirm the permanent Android application ID, production signing, versioning, and release artifact provenance.
- [ ] **Automated validation:** all current-head CI checks and regression tests pass.
- [ ] **Independent review:** review privacy, threat model, backup/recovery, and operational access controls.

Do not describe the app as production-ready until each applicable item is evidenced. The absence of an app PIN/biometric gate is an intentional product choice, not a security control.
