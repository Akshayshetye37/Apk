#!/usr/bin/env python3
"""Static guardrails for Aurelia PMS. Not a penetration test."""
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[1]
html = (root / 'assets/index.html').read_text(encoding='utf-8')
main = (root / 'lib/main.dart').read_text(encoding='utf-8')
backup = (root / 'scripts/interaction_reliability.js').read_text(encoding='utf-8')
file_viewing = (root / 'scripts/file_viewing.js').read_text(encoding='utf-8')
gateway = (root / 'backend/ai-gateway/worker.js').read_text(encoding='utf-8')
pub = (root / 'pubspec.yaml').read_text(encoding='utf-8')
lock = (root / 'pubspec.lock').read_text(encoding='utf-8') if (root / 'pubspec.lock').is_file() else ''
manifest = (root / 'android/app/src/main/AndroidManifest.xml').read_text(encoding='utf-8')
activity = (root / 'android/app/src/main/kotlin/com/example/aurelia_pms/MainActivity.kt').read_text(encoding='utf-8')
errors=[]
if 'contentType !== "application/json"' not in gateway or 'total > 8192' not in gateway or 'reader.cancel()' not in gateway:
 errors.append('AI gateway must require JSON and enforce the request-size limit while streaming the body.')
if 'constantTimeEqual(supplied, env.AURELIA_GATEWAY_TOKEN)' not in gateway or 'store: false' not in gateway:
 errors.append('AI gateway authentication or provider no-storage request safeguard is missing.')
if not html.strip(): errors.append('Bundled PMS HTML asset is empty; refusing to package a blank app.')
if 'AureliaEncryptedPmsStore' not in main or 'AesGcm.with256bits()' not in main or "value['type'] == 'savePmsData'" not in main: errors.append('Encrypted native PMS database storage bridge is missing.')
if 'window.__AURELIA_SECURE_DB_BOOTSTRAP' not in html or 'aureliaWaitForSecureSave' not in html or 'nativeSecure' not in html: errors.append('WebView database bootstrap/migration to encrypted native storage is missing.')
if 'Content-Security-Policy' not in html or "script-src 'self' 'unsafe-inline'" not in html: errors.append('WebView content security policy must block remote script execution.')
if 'aureliaGoogleDriveSettingsCard' in html or any(token in file_viewing for token in ('aureliaDriveFolderId', 'aureliaDriveEmail', 'aureliaSaveDriveFolderId', 'aureliaClearDriveFolderId')): errors.append('Nonfunctional Google Drive destination controls must not be exposed.')
if re.search(r'<script\b[^>]+src=["\']https?://', html, re.I) or not re.search(r"connect-src\s+['\"]?self['\"]?\s+blob:", html, re.I): errors.append('Remote executable scripts must be absent and WebView network access must match the configured offline policy.')
if 'Pbkdf2(' not in main or 'exportEncryptedBackup' not in main or 'restoreEncryptedBackup' not in main: errors.append('Portable passphrase-encrypted backup/restore is missing.')
# The product owner explicitly requested removal of PIN and biometric access controls.
# Guard against accidentally reintroducing UI, native gates, plugin dependencies, or permissions.
if re.search(r'PmsAccessGate|_unlockAndLoad|_unlocked|LocalAuthentication|local_auth|aurelia_pms_pin|aurelia_pms_biometric|getAuthPreferences|setBiometricEnabled|setPinEntryEnabled|setAppProtection|_lockUntilKey|pinEntryPreference|biometricPreference', main, re.I):
 errors.append('PIN/biometric access-control implementation must be fully removed from the native app.')
if re.search(r'local_auth\s*:', pub) or 'android.permission.USE_BIOMETRIC' in manifest:
 errors.append('PIN/biometric plugin dependency or Android permission remains after requested removal.')
if re.search(r'App security|Require PIN|PIN recovery|Backup & device security|Enable device biometric|Test device biometric|aureliaPinInput|aureliaSetPin|aureliaEnrollBiometric|aureliaVerifyBiometric', html, re.I):
 errors.append('PIN/biometric settings UI or helper implementation remains.')
if '__aureliaRoomBillingGuardInstalled' not in backup or 'active checked-in guest' not in backup or 'Number(item && item.sell)' not in backup or "requestedSource === 'stock'" not in backup: errors.append('Room billing must validate active stays, canonical menu prices, and saleable stock items.')
if 'room billing requires an active stay' not in (root / 'tests/backup_import.test.js').read_text(encoding='utf-8').lower() or 'room billing canonicalizes prices' not in (root / 'tests/backup_import.test.js').read_text(encoding='utf-8').lower(): errors.append('Room billing regression tests are missing.')
if 'quickchart.io/qr' in html.lower() or 'api.qrserver.com' in html.lower(): errors.append('External QR generation service remains in HTML.')
if "markFolioPaid" in html or "manual_external_check" in html: errors.append('A folio must never be settled by a manual UI action; settlement requires a verified gateway webhook.')
if any(token in html for token in ('aureliaBackupSecurityPanel', 'aureliaBackupSettingsHTML', 'aureliaDriveAccessToken', 'aureliaConnectDrive', 'aureliaUploadDriveBackup', 'aureliaGoogleClientId', 'Google Drive backup')): errors.append('Removed Google Drive settings panel or disabled cloud backup handlers are still exposed.')
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
