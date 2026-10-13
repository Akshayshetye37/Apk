#!/usr/bin/env python3
"""Static release guardrails for Aurelia PMS; not a penetration test."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
html = (root / "assets/index.html").read_text(encoding="utf-8")
main = (root / "lib/main.dart").read_text(encoding="utf-8")
pub = (root / "pubspec.yaml").read_text(encoding="utf-8")
manifest = (root / "android/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
gradle = (root / "android/app/build.gradle.kts").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/build-apk.yml").read_text(encoding="utf-8")
errors = []

# Unsafe legacy import and plaintext cloud backup must stay disabled until safe implementations exist.
if "Import blocked for data safety" not in html:
    errors.append("Unsafe direct JSON import must remain disabled until a staged, validated restore exists.")
if "does not yet encrypt backup contents" not in html or "return false;" not in html[html.find("function aureliaUploadDriveBackup"):html.find("function aureliaQueueDriveBackup")]:
    errors.append("Plaintext cloud backup must remain disabled until authenticated encryption and recovery are implemented.")

# Persistent storage failure must not silently downgrade to volatile in-memory storage.
if "refusing volatile-memory mode" not in html or "Persistent storage is unavailable" not in html:
    errors.append("PMS must fail closed rather than claim durability when persistent storage is unavailable.")

# Corrupt or unrecognized stored PMS data must never silently fall back to demo seed data.
if "const hasStoredData=primary!==null||backup!==null;" not in html or "if(hasStoredData)" not in html:
    errors.append("PMS storage recovery must fail closed when existing stored records cannot be parsed or validated.")
if "No demo data was loaded and no stored copy was overwritten" not in html:
    errors.append("PMS corruption path must preserve stored records instead of silently loading demo data.")

if "quickchart.io/qr" in html.lower() or "api.qrserver.com" in html.lower():
    errors.append("External QR generation service remains in HTML.")
if "aureliaRequestLocalQr" not in html or "generateQr" not in main:
    errors.append("Local QR bridge is missing.")
if "type:'shareFile'" not in html or "value['type'] == 'shareFile'" not in main:
    errors.append("Native file export bridge is missing.")
if 'android:allowBackup="false"' not in manifest:
    errors.append("Android backup must remain disabled.")
if 'android:usesCleartextTraffic="false"' not in manifest:
    errors.append("Cleartext HTTP must remain disabled.")
if 'android:dataExtractionRules="@xml/data_extraction_rules"' not in manifest:
    errors.append("Android backup/device-transfer extraction exclusions are not configured.")
if not (root / "android/app/src/main/res/xml/data_extraction_rules.xml").is_file():
    errors.append("Android data extraction rules file is missing.")
if "NavigationDecision.prevent" not in main or "/android_asset/flutter_assets/" not in main:
    errors.append("WebView must block non-local top-level navigation while the JS bridge is installed.")
if re.search(r"uses-permission[^>]+(CAMERA|RECORD_AUDIO|READ_SMS|READ_CONTACTS|MANAGE_EXTERNAL_STORAGE)", manifest):
    errors.append("Review unexpected sensitive Android permissions.")
for line in pub.splitlines():
    if re.match(r"\s{2}[a-zA-Z0-9_]+:\s+\^", line):
        errors.append("Unpinned direct dependency: " + line.strip())
        break
# Native-backed app lock: PBKDF2 verifier, throttling, lifecycle and inactivity timeout.
kotlin = (root / "android/app/src/main/kotlin/com/example/aurelia_pms/MainActivity.kt").read_text(encoding="utf-8")
for required in ("PBKDF2WithHmacSHA256", "derivePinHash", "authenticateDevice", "createConfirmDeviceCredentialIntent"):
    if required not in kotlin:
        errors.append("Native app-lock security implementation is missing " + required + ".")
for required in ("app_pin_hash_v1", "app_pin_salt_v1", "app_pin_lock_until_v1", "Duration(minutes: 5)", "WidgetsBindingObserver"):
    if required not in main:
        errors.append("App lock is missing required control " + required + ".")

if "base64Decode(dataValue)" not in main or "15 * 1024 * 1024" not in main:
    errors.append("Native export size validation missing.")
if "replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')" not in main:
    errors.append("Native filename sanitization missing.")

# Release signing must fail closed in the committed Gradle configuration.
for env_name in (
    "ANDROID_KEYSTORE_PATH",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
):
    if env_name not in gradle:
        errors.append("Gradle release signing does not read " + env_name + ".")
if "GradleException" not in gradle:
    errors.append("Gradle release signing must fail with GradleException when secrets are missing.")
if 'signingConfig = signingConfigs.getByName("debug")' in gradle:
    errors.append("Release build must never fall back to debug signing.")
if 'signingConfig = signingConfigs.getByName("release")' not in gradle:
    errors.append("Release build is not explicitly configured to use release signing.")
if "sed -i" in workflow:
    errors.append("Build workflow mutates Dart source with sed; remove source mutations.")
if "needs: validate" not in workflow:
    errors.append("APK build job must depend on successful validation.")
if "flutter pub get --enforce-lockfile" not in workflow:
    errors.append("Workflow must resolve dependencies with --enforce-lockfile.")
if "pubspec.lock" not in workflow:
    errors.append("Workflow must require the committed dependency lockfile.")

if errors:
    print("STATIC SECURITY CHECK FAILED:")
    for error in errors:
        print("- " + error)
    sys.exit(1)
print("Static release guardrails passed. This is not a full audit or device test.")
