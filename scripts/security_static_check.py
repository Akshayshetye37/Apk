#!/usr/bin/env python3
"""Static guardrails for Aurelia PMS. Not a penetration test."""
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[1]
html = (root / 'assets/index.html').read_text(encoding='utf-8')
main = (root / 'lib/main.dart').read_text(encoding='utf-8')
gate = (root / 'lib/pms_access_gate.dart').read_text(encoding='utf-8')
backup = (root / 'scripts/interaction_reliability.js').read_text(encoding='utf-8')
file_viewing = (root / 'scripts/file_viewing.js').read_text(encoding='utf-8')
pub = (root / 'pubspec.yaml').read_text(encoding='utf-8')
lock = (root / 'pubspec.lock').read_text(encoding='utf-8') if (root / 'pubspec.lock').is_file() else ''
manifest = (root / 'android/app/src/main/AndroidManifest.xml').read_text(encoding='utf-8')
activity = (root / 'android/app/src/main/kotlin/com/example/aurelia_pms/MainActivity.kt').read_text(encoding='utf-8')
errors=[]
if not html.strip(): errors.append('Bundled PMS HTML asset is empty; refusing to package a blank app.')
if 'AureliaEncryptedPmsStore' not in main or 'AesGcm.with256bits()' not in main or "value['type'] == 'savePmsData'" not in main: errors.append('Encrypted native PMS database storage bridge is missing.')
if 'window.__AURELIA_SECURE_DB_BOOTSTRAP' not in html or 'aureliaWaitForSecureSave' not in html or 'nativeSecure' not in html: errors.append('WebView database bootstrap/migration to encrypted native storage is missing.')
if 'Content-Security-Policy' not in html or "script-src 'self' 'unsafe-inline'" not in html: errors.append('WebView content security policy must block remote script execution.')
if 'aureliaGoogleDriveSettingsCard' in html or any(token in file_viewing for token in ('aureliaDriveFolderId', 'aureliaDriveEmail', 'aureliaSaveDriveFolderId', 'aureliaClearDriveFolderId')): errors.append('Nonfunctional Google Drive destination controls must not be exposed.')
if re.search(r'<script\b[^>]+src=["\']https?://', html, re.I) or "connect-src 'self' blob:" not in html: errors.append('Remote executable scripts must be absent and WebView network access must match the configured offline policy.')
if 'Pbkdf2(' not in main or 'exportEncryptedBackup' not in main or 'restoreEncryptedBackup' not in main: errors.append('Portable passphrase-encrypted backup/restore is missing.')
if 'local_auth: 2.3.0' not in pub or 'FlutterFragmentActivity' not in activity or 'android.permission.USE_BIOMETRIC' not in manifest: errors.append('Native PIN/device authentication support is incomplete.')
if '_lockUntilKey' not in gate or '310000' not in gate or 'didChangeAppLifecycleState' not in main: errors.append('PIN lockout or background-session locking is missing.')
if 'PmsAccessGate' not in main or 'local_auth' not in gate: errors.append('Native PIN/device authentication gate is missing.')
if "if (!enabled)" not in main or 'App protection cannot be disabled in this secure build.' not in main: errors.append('Native app protection must fail closed when web content requests disabling the lock.')
if "if (enabled === false)" not in file_viewing or 'App protection cannot be disabled in this secure build.' not in file_viewing: errors.append('Web settings bridge must not expose an app-lock disable action.')
if '__aureliaRoomBillingGuardInstalled' not in backup or 'active checked-in guest' not in backup or 'Number(item && item.sell)' not in backup or "requestedSource === 'stock'" not in backup: errors.append('Room billing must validate active stays, canonical menu prices, and saleable stock items.')
if 'room billing requires an active stay' not in (root / 'tests/backup_import.test.js').read_text(encoding='utf-8').lower() or 'room billing canonicalizes prices' not in (root / 'tests/backup_import.test.js').read_text(encoding='utf-8').lower(): errors.append('Room billing regression tests are missing.')
if 'quickchart.io/qr' in html.lower() or 'api.qrserver.com' in html.lower(): errors.append('External QR generation service remains in HTML.')
if "markFolioPaid" in html or "manual_external_check" in html: errors.append('A folio must never be settled by a manual UI action; settlement requires a verified gateway webhook.')
if "Google Drive sync is disabled in this Android build" not in html: errors.append('The UI must clearly disclose that Google Drive sync is disabled in this Android build.')
if 'aureliaRequestLocalQr' not in html or 'generateQr' not in main: errors.append('Local QR bridge is missing.')
if 'shareFile' not in html or "value['type'] == 'shareFile'" not in main: errors.append('Native file export bridge is missing.')
if 'android:allowBackup="false"' not in manifest: errors.append('Android backup must remain disabled.')
if 'android:usesCleartextTraffic="false"' not in manifest: errors.append('Cleartext HTTP must remain disabled.')
if 'NavigationDecision.prevent' not in main or '/android_asset/flutter_assets/' not in main: errors.append('WebView must block non-local top-level navigation while the JS bridge is installed.')
if re.search(r'uses-permission[^>]+(CAMERA|RECORD_AUDIO|READ_SMS|READ_CONTACTS|MANAGE_EXTERNAL_STORAGE)',manifest): errors.append('Review unexpected sensitive Android permissions.')
# Direct package ranges are safely reproducible when a lockfile entry is present
# and CI runs flutter pub get --enforce-lockfile.
if not lock.strip():
 errors.append('pubspec.lock is missing; CI must not resolve dependencies without a committed lockfile.')
else:
 locked_packages = {m.group(1) for m in re.finditer(r'^  ([a-zA-Z0-9_]+):\n(?:(?!^  [a-zA-Z0-9_]+:).)*?^    version: ', lock, re.M | re.S)}
 for line in pub.splitlines():
  match = re.match(r'\s{2}([a-zA-Z0-9_]+):\s+\^([^\s]+)', line)
  if match and match.group(1) not in locked_packages:
   errors.append('Direct dependency is not pinned by a lockfile entry: '+match.group(1))
if 'base64Decode(dataValue)' not in main or '15 * 1024 * 1024' not in main: errors.append('Native export size validation missing.')
if 'function validateBackup(data)' not in backup or 'FORBIDDEN_KEYS' not in backup: errors.append('Backup import schema and prototype-pollution validation is missing.')
if 'restoreEncryptedBackup' not in backup or 'aureliaNativeBackupRestoreResult' not in backup: errors.append('Encrypted portable backup restore is missing.')
if '20 * 1024 * 1024' not in backup or 'formatVersion' not in backup: errors.append('Backup size or format-version validation is missing.')
if 'NOT encrypted' not in backup or 'exportEncryptedBackup' not in backup: errors.append('Encrypted Android backup export or plaintext preview warning is missing.')
if not (root / 'tests/backup_import.test.js').is_file(): errors.append('Backup import regression tests are missing.')
if not (root / 'test/backup_crypto_test.dart').is_file(): errors.append('Portable backup cryptography regression tests are missing.')
if "replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')" not in main: errors.append('Native filename sanitization missing.')
# Booking identity photos must survive editing and be included in record exports.
if "pendingBookingIdPhoto" not in html or "aureliaOccupantImageChanged" not in html or "saveBookingForm(id)" not in html:
 errors.append('Booking and guest occupant ID photos must persist from the edit form into saved records.')
if "pendingBookingIdPhoto" not in html or "g?.idPhoto" not in html or 'id="bkIdPreview"' not in html:
 errors.append('Existing primary guest ID photos must reload when editing a booking.')
if 'id="bkIdPreview"' not in html or "aureliaOccupantImageChanged" not in html:
 errors.append('Booking exports must include primary guest and occupant identity records/photos.')
if 'cdn.jsdelivr.net/npm/tesseract' in html or 'recognizeIdImage' not in html:
 errors.append('ID OCR must use the local native bridge rather than a remote CDN dependency.')
if errors:
 print('STATIC SECURITY CHECK FAILED:'); [print('- '+e) for e in errors]; sys.exit(1)
print('Static security guardrails passed. Not a full audit or device test.')
