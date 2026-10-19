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
    'savePmsData', 'exportEncryptedBackup', 'restoreEncryptedBackup',
    'aureliaRequestLocalQr', 'generateQr'
  ]) {
    assert.ok(html.includes(token), 'missing workflow token: ' + token);
  }
  for (const token of ['exportEncryptedBackup', 'restoreEncryptedBackup']) {
    assert.ok(dart.includes(token), 'missing native backup workflow: ' + token);
  }
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
