#!/usr/bin/env python3
"""Static guardrails for Aurelia PMS. Not a penetration test."""
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[1]
html = (root / 'assets/index.html').read_text(encoding='utf-8')
main = (root / 'lib/main.dart').read_text(encoding='utf-8')
pub = (root / 'pubspec.yaml').read_text(encoding='utf-8')
manifest = (root / 'android/app/src/main/AndroidManifest.xml').read_text(encoding='utf-8')
errors=[]
if 'quickchart.io/qr' in html.lower() or 'api.qrserver.com' in html.lower(): errors.append('External QR generation service remains in HTML.')
if 'aureliaRequestLocalQr' not in html or 'generateQr' not in main: errors.append('Local QR bridge is missing.')
if "type:'shareFile'" not in html or "value['type'] == 'shareFile'" not in main: errors.append('Native file export bridge is missing.')
if 'android:allowBackup="false"' not in manifest: errors.append('Android backup must remain disabled.')
if 'android:usesCleartextTraffic="false"' not in manifest: errors.append('Cleartext HTTP must remain disabled.')
if re.search(r'uses-permission[^>]+(CAMERA|RECORD_AUDIO|READ_SMS|READ_CONTACTS|MANAGE_EXTERNAL_STORAGE)',manifest): errors.append('Review unexpected sensitive Android permissions.')
for line in pub.splitlines():
 if re.match(r'\s{2}[a-zA-Z0-9_]+:\s+\^',line): errors.append('Unpinned direct dependency: '+line.strip()); break
if 'base64Decode(dataValue)' not in main or '15 * 1024 * 1024' not in main: errors.append('Native export size validation missing.')
if "replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')" not in main: errors.append('Native filename sanitization missing.')
if errors:
 print('STATIC SECURITY CHECK FAILED:'); [print('- '+e) for e in errors]; sys.exit(1)
print('Static security guardrails passed. Not a full audit or device test.')
