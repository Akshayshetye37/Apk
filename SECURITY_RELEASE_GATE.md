# Aurelia PMS production release security gate

**Current decision: NOT APPROVED FOR PRODUCTION.** A successful Flutter build is not evidence that local PMS data is encrypted or that backup recovery, uploads, or printing work correctly.

## CI gate

The `.github/workflows/production-security-gate.yml` workflow pins Flutter 3.35.5, requires a committed `pubspec.lock`, enforces locked dependency resolution, and runs static analysis and Flutter tests. Its main-branch/manual signing preflight requires the four repository Actions secrets below and validates that the encoded keystore, store password, and alias can be opened by `keytool`. It never prints secret values.

Required repository secrets:
- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The gate is a preflight, not a replacement for reviewing the release workflow, verifying the APK signature and certificate fingerprint, or checking the produced artifact.

## Mandatory implementation and evidence checklist

Do not mark a control complete until implementation and repeatable test evidence exist.

- [ ] Authentication is enforced before PMS data is exposed; retry limits and timed lockout are implemented and tested. Test biometric flows on supported hardware.
- [ ] PMS records currently stored in WebView `localStorage` are migrated to vetted encrypted storage. Key material is protected by Android Keystore-backed mechanisms; migration is integrity-checked, idempotent, and recoverable without data loss.
- [ ] Backup files use vetted authenticated encryption (for example, an established AES-GCM implementation) with unique nonces and keys kept separately from backup files. Do not invent a cryptographic format.
- [ ] Restore rejects wrong credentials, tampering, truncation, corruption, and unsupported versions; it must not overwrite valid data until validation succeeds.
- [ ] Google Drive authorization, resumable/interrupted upload, durable retries, duplicate/conflicting version handling, and restore recovery are implemented and tested.
- [ ] Native PDF generation and Android print APIs handle long reports, page breaks, unsafe content, cancellation, and temporary-file cleanup.
- [ ] CSV formula-injection protections and export contents are tested; backup sharing is permitted only for verified encrypted backups.
- [ ] Tests cover authentication, lockout, migration, encryption/decryption, tamper detection, backup/restore, upload interruption/retry, CSV/PDF, and failure paths.
- [ ] Install the release APK on physical Android device(s); verify launch, upgrade/install behavior, exports, print preview and physical printing, sharing, and backup recovery.
- [ ] Use only fictional guest, booking, and payment data for device validation. Record device model, Android version, APK SHA-256, signer certificate fingerprint, CI run, test results, and unresolved defects.

## Evidence record

| Evidence | Result |
| --- | --- |
| Source commit / CI run | Pending |
| Locked dependency resolution | Pending |
| Analysis and automated tests | Pending |
| Release signing and APK certificate verification | Pending |
| Physical-device install and launch | Pending |
| Encrypted backup tamper/recovery tests | Pending |
| Interrupted upload/retry tests | Pending |
| PDF generation and Android physical printing | Pending |

**Release policy:** Keep release status blocked while any mandatory control is missing, failing, or unverified. CI cannot perform physical-device validation and cannot prove application security solely from a successful build.
