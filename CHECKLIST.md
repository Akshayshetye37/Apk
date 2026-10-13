# Aurelia PMS APK — Complete Project Checklist

**Rule:** Do not check off an item until it has actually been verified. A successful CI build does not prove that the app works correctly on a phone.

## 1. GitHub repository

- [x] `pubspec.yaml` exists at the repository root.
- [x] `lib/main.dart` exists.
- [x] `assets/index.html` exists and is the HTML asset bundled by the build workflow.
- [x] `.github/workflows/build-apk.yml` exists.
- [x] Android manifest and Gradle configuration files are committed under `android/`.
- [x] Checklist and build instructions are committed.
- [ ] Android Gradle configuration builds successfully with the current Flutter stable release.
- [ ] Latest intended changes are on `main` and the corresponding Actions run has been inspected.

## 2. GitHub Actions

- [x] Build workflow is defined for GitHub Actions.
- [ ] Latest workflow run completes successfully.
- [ ] No dependency, Dart, Android, or Gradle build errors.
- [ ] APK artifact `aurelia-pms-release-apk` is generated and downloadable.
- [ ] APK signature verification step passes.
- [ ] APK installs successfully on a real Android phone.
- [ ] Production signing is configured with the intended release keystore before public distribution.

## 3. App features

- [ ] Dashboard opens without a blank screen or crash.
- [ ] Rooms, reservations, bookings, folios, and reports work.
- [ ] Data persists after closing and reopening the app.
- [ ] Core offline features work in airplane mode.
- [ ] Online-only features show a sensible offline message.
- [ ] Fresh installs do not contain demo transactions that inflate financial reports.
- [ ] Removing demo entries preserves real guests, bookings, expenses, payments, and other genuine records.
- [ ] Date/time display and operational day boundaries use `Asia/Kolkata` (IST, UTC+05:30), even when the phone timezone differs.

## 4. PDF, CSV, and files

- [ ] CSV export creates a real, usable file with correct data.
- [ ] PDF export creates a valid, readable PDF.
- [ ] Files can be saved or shared through Android.
- [ ] No `blob:null`, `ERR_FILE_NOT_FOUND`, or blank PDF errors.
- [ ] Import and backup work, if those features are supported.
- [ ] Exported timestamps and date-based filenames use the intended India-local date/time where appropriate.

## 5. Android permissions

- [ ] Camera permission is requested only when needed.
- [ ] Photo selection uses Android's photo picker where possible.
- [ ] Microphone permission is requested only if audio recording is supported.
- [ ] Document picker can open user-selected files.
- [ ] Notification permission is requested if notifications are used.
- [ ] Denying permissions does not crash the app.
- [ ] No unnecessary sensitive permissions are requested.

## 6. Android reliability

- [ ] Android Back button works correctly.
- [ ] App works after restarting the phone.
- [ ] No blank screen or JavaScript errors during tested workflows.
- [ ] App signing and package ID are configured correctly.
- [ ] All major features are tested on a real device.
- [ ] Saved data survives app restarts; data retention after reinstall is documented and tested separately.
- [ ] Local storage, backup/export, and sensitive PMS data handling are reviewed.

## 7. If an error occurs

- **`pubspec.yaml` not found:** Check repository folder structure and the ZIP extraction step.
- **Dart import/dependency error:** Check imports and `pubspec.yaml`.
- **`assembleRelease` failed:** Inspect the first meaningful Gradle error in the Actions log.
- **Permission denied:** Inspect the Android manifest and runtime permission handling.
- **CSV `ERR_FILE_NOT_FOUND`:** Inspect WebView Blob/download handling and Android file access.
- **PDF blank or failed:** Inspect PDF generation, fonts, print flow, and file sharing.
- **Blank app screen:** Inspect asset paths, WebView errors, and JavaScript errors.
- **Data disappears:** Inspect WebView origin/storage behavior and persistence settings.
- **Wrong date near midnight:** Test date-only values, ISO timestamps, and calendar boundaries using `Asia/Kolkata` while the device is set to another timezone.

When a build fails, copy the first meaningful error from the GitHub Actions log into the issue or troubleshooting notes. Do not report the build as successful until a later run passes.

## Final status

- [ ] Repository files verified.
- [ ] GitHub Actions build successful.
- [ ] APK downloaded and installed.
- [ ] Permissions tested.
- [ ] Offline mode tested.
- [ ] PDF/CSV export tested.
- [ ] India timezone behavior tested on a real device.


## Security review and testing

- [x] Static security guardrail script added to CI.
- [ ] QR generation tested with airplane mode enabled and no external QR requests.
- [ ] CSV/JSON export shared from an actual APK and opened in a compatible app.
- [ ] Native bridge rejects oversized payloads, invalid MIME types, path traversal filenames, and unsupported message types.
- [ ] Unauthorized access and incorrect PIN attempts tested against the actual APK; client-side PIN checks are not server authentication.
- [ ] Permission denial tested on device.
- [ ] Tampered backups and malformed/oversized imports rejected without corrupting existing records.
- [ ] Offline dashboard, bookings, reports, and exports tested on device.
- [ ] Local storage threat model reviewed; PMS records are not encrypted merely by native secure storage.
- [ ] Production data approved only after authentication and at-rest protections are implemented and tested.
