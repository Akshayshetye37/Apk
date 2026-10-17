const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const html = fs.readFileSync(path.join(__dirname, '..', 'assets', 'index.html'), 'utf8');

test('bundled PMS UI is present and has no remote script dependency', () => {
  assert.ok(html.trim().length > 5000, 'bundled HTML must not be blank');
  assert.match(html, /Content-Security-Policy/);
  assert.match(html, /connect-src 'none'/);
  assert.doesNotMatch(html, /<script\b[^>]+src=["']https?:\/\//i);
});

test('core property workflows are exposed in the bundled UI', () => {
  for (const token of ['id="view-guests"', 'id="view-rooms"', 'id="view-bookings"',
    'id="view-folios"', 'id="view-settings"', 'savePmsData', 'exportEncryptedBackup',
    'restoreEncryptedBackup', 'aureliaRequestLocalQr', 'generateQr']) {
    assert.ok(html.includes(token), 'missing workflow token: ' + token);
  }
});

test('guest and occupant identity images are retained in records and booking export', () => {
  for (const token of ['idPhoto:photo', 'idPhoto:pendingPhotos.occupants[i]',
    'id="bkIdPreview"', 'aurelia_booking_bundle_v1', 'occupants']) {
    assert.ok(html.includes(token), 'missing identity persistence token: ' + token);
  }
});

test('folio QR explicitly keeps payment pending until independent verification', () => {
  assert.match(html, /Payment remains pending until a trusted gateway webhook is verified/);
  assert.match(html, /Pending gateway verification/);
  assert.doesNotMatch(html, /markFolioPaid|manual_external_check|folio\.status\s*=\s*['\"]Paid['\"]/);
  assert.doesNotMatch(html, /NotificationListenerService|READ_SMS|READ_NOTIFICATION/);
});
