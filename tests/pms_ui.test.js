const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const html = fs.readFileSync(path.join(__dirname, '..', 'assets', 'index.html'), 'utf8');
const dart = fs.readFileSync(path.join(__dirname, '..', 'lib', 'main.dart'), 'utf8');

test('bundled PMS UI is present and does not depend on remote scripts', () => {
  assert.ok(html.trim().length > 5000, 'bundled HTML must not be blank');
  assert.match(html, /Content-Security-Policy/);
  assert.match(html, /connect-src 'self' blob:/);
  assert.doesNotMatch(html, /<script\b[^>]+src=["']https?:\/\//i);
});

test('actual page router exposes separate hotel, restaurant, billing and settings workflows', () => {
  for (const token of [
    'const pages={', 'dashboard:pagesDashboard', 'guests:pagesGuests',
    'rooms:pagesRooms', 'bookings:pagesBookings', 'folio:pagesFolio',
    'pos:pagesPOS', 'settings:pagesSettings', 'function showPage(id)',
    'savePmsData', 'aureliaRequestLocalQr', 'generateQr'
  ]) {
    assert.ok(html.includes(token), 'missing workflow token: ' + token);
  }
  for (const token of [
    "value['type'] == 'exportEncryptedBackup'",
    "value['type'] == 'restoreEncryptedBackup'"
  ]) {
    assert.ok(dart.includes(token), 'missing native backup workflow handler: ' + token);
  }
  const interaction = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'interaction_reliability.js'), 'utf8');
  assert.match(interaction, /type:\s*'exportEncryptedBackup'/);
  assert.match(interaction, /type:\s*'restoreEncryptedBackup'/);
  assert.match(html, /function pagesSettingsNew\(\)/);
  assert.match(html, /food-only|food items|guest room/i);
});

test('guest and occupant identity images are retained in records and booking export', () => {
  for (const token of ['pendingBookingIdPhoto', 'aureliaOccupantImageChanged',
    'id="bkIdPreview"', 'function saveBookingForm(id)', 'occupants']) {
    assert.ok(html.includes(token), 'missing identity persistence token: ' + token);
  }
});

test('payments require explicit verification and enforce amount bounds', () => {
  assert.match(html, /if\(!verify\|\|!verify\.checked\)/);
  assert.match(html, /Payment manually confirmed/);
  assert.match(html, /if\(amt>outstanding\)/);
  assert.doesNotMatch(html, /NotificationListenerService|READ_SMS|READ_NOTIFICATION/);
});

test('obsolete AI settings are removed while data-integrity checks remain available', () => {
  assert.doesNotMatch(html, /aureliaInternetToggle|aureliaAiToggle|aureliaAiGatewayUrl|aureliaConnectivityAiCard/);
  assert.match(html, /id="aureliaDataIntegrityCard"/);
  assert.match(html, /async function runAureliaHealthCheck\(\)/);
  assert.match(html, /Local-only mode · cloud sync not configured/);
  assert.doesNotMatch(html, /feature_keys_placeholder=undefined|Google Drive connection — coming later/);
});

test('health check is read-only until confirmed and repair preserves existing records', async () => {
  const vm = require('node:vm');
  const start = html.indexOf('async function runAureliaHealthCheck(){');
  const end = html.indexOf('\nwindow.__AURELIA_AI_CONFIG=', start);
  assert.ok(start >= 0 && end > start, 'health-check implementation must be discoverable');
  const source = html.slice(start, end);
  async function harness({db, confirmResult = false, saveThrows = false, secureSaveFails = false}) {
    const report = {textContent: '', style: {}};
    const auditEvents = [];
    const context = {
      DB: db,
      document: {getElementById: id => id === 'aureliaHealthReport' ? report : null},
      window: {confirm: () => confirmResult, aureliaWaitForSecureSave: async () => { if (secureSaveFails) throw new Error('simulated encrypted save failure'); }},
      audit: (...args) => auditEvents.push(args),
      save: () => { if (saveThrows) throw new Error('simulated save failure'); },
      String,
      Object,
      Array,
      Set,
      Error
    };
    vm.runInNewContext(source, context);
    await context.runAureliaHealthCheck();
    return {db, report, auditEvents};
  }

  const existingGuest = {id: 'guest-1', name: 'Preserve me'};
  const complete = {rooms: [], guests: [existingGuest], bookings: [], reservations: []};
  const before = JSON.stringify(complete);
  await harness({db: complete});
  assert.equal(JSON.stringify(complete), before, 'inspection must not mutate a complete database');

  const missing = {rooms: [], guests: [existingGuest], bookings: []};
  const cancelled = await harness({db: missing, confirmResult: false});
  assert.equal(Object.hasOwn(missing, 'inventory'), false, 'cancelled repair must not add a collection');
  assert.match(cancelled.report.textContent, /Repair cancelled; no data changed/);
  assert.equal(missing.guests[0], existingGuest, 'existing guest object must be retained');

  const failed = {rooms: [], guests: [existingGuest], bookings: []};
  const failedResult = await harness({db: failed, confirmResult: true, secureSaveFails: true});
  assert.equal(Object.hasOwn(failed, 'inventory'), false, 'failed save must roll back newly added collections');
  assert.equal(failed.guests[0], existingGuest, 'failed repair must preserve guest records');
  assert.match(failedResult.report.textContent, /Safe repair failed/);

  const repaired = {rooms: [], guests: [existingGuest], bookings: [], invoices: 'malformed'};
  const repairedResult = await harness({db: repaired, confirmResult: true});
  assert.ok(Array.isArray(repaired.inventory), 'confirmed repair may add missing empty collections');
  assert.equal(repaired.invoices, 'malformed', 'repair must not overwrite malformed existing sections');
  assert.equal(repaired.guests[0], existingGuest, 'repair must preserve guest records');
  assert.match(repairedResult.report.textContent, /left unchanged|manual review/i);
});

test('online AI gateway bounds request bodies and requires authenticated JSON', () => {
  const worker = fs.readFileSync(path.join(__dirname, '..', 'backend', 'ai-gateway', 'worker.js'), 'utf8');
  assert.match(worker, /contentType !== "application\/json"/);
  assert.match(worker, /contentLength > 8192/);
  assert.match(worker, /total > 8192/);
  assert.match(worker, /reader\.cancel\(\)/);
  assert.match(worker, /constantTimeEqual\(supplied, env\.AURELIA_GATEWAY_TOKEN\)/);
  assert.match(worker, /store: false/);
  assert.doesNotMatch(worker, /console\.(log|error)\([^\n]*(question|token|body)/i);
});


test('Settings do not expose duplicate browser PIN/biometric controls or online AI gateway setup', () => {
  assert.doesNotMatch(html, /Backup & device security|PIN recovery \/ device authentication|Enable device biometric|Test device biometric|Set \/ reset PIN/);
  assert.doesNotMatch(html, /aureliaConnectivityAiCard|Secure AI gateway URL|Gateway access token|Online AI gateway:/);
  assert.doesNotMatch(dart, /unawaited\(_installAureliaAssistant\(\)\)/);
  assert.doesNotMatch(dart, /Online AI is not configured\. Add your own authenticated HTTPS gateway in Settings/);
  assert.match(html, /id="aureliaDataIntegrityCard"/);
  assert.match(html, /onclick="runAureliaHealthCheck\(\)"/);
  // Native app-lock gate remains implemented separately and is not removed with
  // these obsolete in-WebView controls.
  assert.doesNotMatch(dart, /PmsAccessGate|_unlockAndLoad|_unlocked/);
  assert.doesNotMatch(dart, /getAuthPreferences|setBiometricEnabled|setPinEntryEnabled|setAppProtection|LocalAuthentication|local_auth|aureliaNativePinEntrySettingResult|aureliaNativeBiometricSettingResult/);
});


test('all rendered button elements have a wired click action and resolvable handler', () => {
  const buttons = [...html.matchAll(/<button\b[^>]*>/gi)].map(match => match[0]);
  assert.ok(buttons.length >= 100, 'expected the full PMS button surface to be scanned');
  const scriptSources = fs.readdirSync(path.join(__dirname, '..', 'scripts'))
    .filter(file => file.endsWith('.js'))
    .map(file => fs.readFileSync(path.join(__dirname, '..', 'scripts', file), 'utf8'))
    .join('\n');
  const sources = html + '\n' + scriptSources;
  for (const button of buttons) {
    assert.match(button, /\bonclick\s*=/i, 'button has no click action: ' + button.slice(0, 180));
    const attribute = button.match(/\bonclick\s*=\s*["']([^"']*)["']/i);
    if (!attribute) continue;
    const handlerText = attribute[1].trim();
    const openParen = handlerText.indexOf('(');
    if (openParen < 1) continue;
    let name = handlerText.slice(0, openParen).trim();
    if (name.startsWith('return ')) name = name.slice(7).trim();
    if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name)) continue;
    const declared =
      new RegExp('\\bfunction\\s+' + name + '\\s*\\(').test(sources) ||
      new RegExp('\\b(?:const|let|var)\\s+' + name + '\\s*=').test(sources) ||
      new RegExp('\\b' + name + '\\s*:\\s*function').test(sources) ||
      new RegExp('window\\.' + name + '\\s*=').test(sources);
    assert.ok(declared, 'button handler is not defined in bundled HTML or scripts: ' + name);
  }
  assert.doesNotMatch(html, /App security|Require PIN \/ device authentication/);
});


test('PIN and biometric security are completely removed and theme is brown and gold', () => {
  assert.doesNotMatch(dart, /PmsAccessGate|_unlockAndLoad|_unlocked|LocalAuthentication|local_auth|aurelia_pms_pin|aurelia_pms_biometric|getAuthPreferences|setBiometricEnabled|setPinEntryEnabled|setAppProtection/);
  assert.doesNotMatch(html, /App security|Require PIN \/ device authentication|Backup & device security|PIN recovery|Enable device biometric|Test device biometric|aureliaPinInput|aureliaSetPin|aureliaEnrollBiometric|aureliaVerifyBiometric|aureliaConnectivityAiCard|Online AI is not configured|Google Drive backup/);
  assert.match(html, /--brand:#7a4b2a/);
  assert.match(html, /--brand2:#b8863b/);
  assert.doesNotMatch(html, /--brand:#17483b|--brand2:#286b56|--brand:#1e5942/);
  assert.doesNotMatch(html, /aureliaBackupSecurityPanel|aureliaBackupSettingsHTML|aureliaDriveAccessToken|aureliaConnectDrive|aureliaUploadDriveBackup|Google Drive sync target/);
  assert.match(html, /Local backup & restore/);
  assert.match(html, /aureliaNativeExportEncryptedBackup/);
});
