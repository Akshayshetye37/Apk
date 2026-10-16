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
manifest = (root / 'android/app/src/main/AndroidManifest.xml').read_text(encoding='utf-8')
activity = (root / 'android/app/src/main/kotlin/com/example/aurelia_pms/MainActivity.kt').read_text(encoding='utf-8')
errors=[]
if 'FLAG_SECURE' not in activity or 'WindowManager.LayoutParams.FLAG_SECURE' not in activity: errors.append('Android FLAG_SECURE must block screenshots and recent-app previews of sensitive PMS screens.')
if not html.strip(): errors.append('Bundled PMS HTML asset is empty; refusing to package a blank app.')
if 'AureliaEncryptedPmsStore' not in main or 'AesGcm.with256bits()' not in main or "value['type'] == 'savePmsData'" not in main: errors.append('Encrypted native PMS database storage bridge is missing.')
if 'window.__AURELIA_SECURE_DB_BOOTSTRAP' not in html or 'aureliaWaitForSecureSave' not in html or 'nativeSecure' not in html: errors.append('WebView database bootstrap/migration to encrypted native storage is missing.')
if 'Content-Security-Policy' not in html or "script-src 'self' 'unsafe-inline'" not in html: errors.append('WebView content security policy must block remote script execution.')
if 'Google Drive sync is disabled in this Android build' not in html: errors.append('Unverified plaintext Google Drive backup must remain disabled.')
if 'window.__AURELIA_SECURE_DB_READY)return false' not in html: errors.append('Dynamic remote PDF JavaScript must remain disabled in the native app.')
if 'Pbkdf2(' not in main or 'exportEncryptedBackup' not in main or 'restoreEncryptedBackup' not in main: errors.append('Portable passphrase-encrypted backup/restore is missing.')
if 'local_auth: 2.3.0' not in pub or 'FlutterFragmentActivity' not in (root / 'android/app/src/main/kotlin/com/example/aurelia_pms/MainActivity.kt').read_text(encoding='utf-8') or 'android.permission.USE_BIOMETRIC' not in manifest: errors.append('Native PIN/device authentication support is incomplete.')
if '_lockUntilKey' not in gate or '310000' not in gate or 'didChangeAppLifecycleState' not in main: errors.append('PIN lockout or background-session locking is missing.')
if 'PmsAccessGate' not in main or 'local_auth' not in gate: errors.append('Native PIN/device authentication gate is missing.')
if "if (!enabled)" not in main or 'App protection cannot be disabled in this secure build.' not in main: errors.append('Native app protection must fail closed when web content requests disabling the lock.')
if "if (enabled === false)" not in file_viewing or 'App protection cannot be disabled in this secure build.' not in file_viewing: errors.append('Web settings bridge must not expose an app-lock disable action.')
if not html.strip(): errors.append('Bundled PMS HTML asset is empty; refusing to package a blank app.')
if 'quickchart.io/qr' in html.lower() or 'api.qrserver.com' in html.lower(): errors.append('External QR generation service remains in HTML.')
if 'aureliaRequestLocalQr' not in html or 'generateQr' not in main: errors.append('Local QR bridge is missing.')
if "type:'shareFile'" not in html or "value['type'] == 'shareFile'" not in main: errors.append('Native file export bridge is missing.')
if 'android:allowBackup="false"' not in manifest: errors.append('Android backup must remain disabled.')
if 'android:usesCleartextTraffic="false"' not in manifest: errors.append('Cleartext HTTP must remain disabled.')
if 'NavigationDecision.prevent' not in main or '/android_asset/flutter_assets/' not in main: errors.append('WebView must block non-local top-level navigation while the JS bridge is installed.')
if re.search(r'uses-permission[^>]+(CAMERA|RECORD_AUDIO|READ_SMS|READ_CONTACTS|MANAGE_EXTERNAL_STORAGE)',manifest): errors.append('Review unexpected sensitive Android permissions.')
for line in pub.splitlines():
 if re.match(r'\s{2}[a-zA-Z0-9_]+:\s+\^',line): errors.append('Unpinned direct dependency: '+line.strip()); break
if 'base64Decode(dataValue)' not in main or '15 * 1024 * 1024' not in main: errors.append('Native export size validation missing.')
if 'function validateBackup(data)' not in backup or 'FORBIDDEN_KEYS' not in backup: errors.append('Backup import schema and prototype-pollution validation is missing.')
if 'restoreEncryptedBackup' not in backup or 'aureliaNativeBackupRestoreResult' not in backup: errors.append('Encrypted portable backup restore is missing.')
if '20 * 1024 * 1024' not in backup or 'formatVersion' not in backup: errors.append('Backup size or format-version validation is missing.')
if 'NOT encrypted' not in backup or 'exportEncryptedBackup' not in backup: errors.append('Encrypted Android backup export or plaintext preview warning is missing.')
if not (root / 'tests/backup_import.test.js').is_file(): errors.append('Backup import regression tests are missing.')
if not (root / 'test/backup_crypto_test.dart').is_file(): errors.append('Portable backup cryptography regression tests are missing.')
if "replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')" not in main: errors.append('Native filename sanitization missing.')
if errors:
 print('STATIC SECURITY CHECK FAILED:'); [print('- '+e) for e in errors]; sys.exit(1)
print('Static security guardrails passed. Not a full audit or device test.')
