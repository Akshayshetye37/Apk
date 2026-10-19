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
  assert.match(interaction, /type:\\s*'exportEncryptedBackup'/);
  assert.match(interaction, /type:\\s*'restoreEncryptedBackup'/);
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

test('internet and AI controls are ordered, persisted, and fail back offline', () => {
  const internet = html.indexOf('id="aureliaInternetToggle"');
  const ai = html.indexOf('id="aureliaAiToggle"');
  assert.ok(internet >= 0, 'Internet feature toggle must exist');
  assert.ok(ai > internet, 'AI toggle must be below the Internet toggle');
  for (const token of [
    'setAureliaConnectivityOption', 'saveAureliaAiGateway',
    'runAureliaHealthCheck', 'installAureliaNetworkGate',
    'saveAiGatewayConfig'
  ]) {
    assert.ok(html.includes(token), 'missing connectivity/AI UI safeguard: ' + token);
  }
  for (const token of ['aureliaAiQuery', 'aurelia_ai_gateway_token_v1',
    'never guest records or billing data', 'HttpHeaders.authorizationHeader']) {
    assert.ok(dart.includes(token), 'missing native AI safeguard: ' + token);
  }
  assert.match(html, /Local-only mode · cloud sync not configured/);
  assert.doesNotMatch(html, /feature_keys_placeholder=undefined|Google Drive connection — coming later/);
});

test('health check is read-only until confirmed and repair preserves existing records', async () => {
  const vm = require('node:vm');
  const start = html.indexOf('function runAureliaHealthCheck(){');
  const end = html.indexOf('\nwindow.__AURELIA_AI_CONFIG=', start);
  assert.ok(start >= 0 && end > start, 'health-check implementation must be discoverable');
  const source = html.slice(start, end);
  async function harness({db, confirmResult = false, saveThrows = false}) {
    const report = {textContent: '', style: {}};
    const auditEvents = [];
    const context = {
      DB: db,
      document: {getElementById: id => id === 'aureliaHealthReport' ? report : null},
      window: {confirm: () => confirmResult},
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
  const failedResult = await harness({db: failed, confirmResult: true, saveThrows: true});
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
