const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync('scripts/native_migration_bridge.js', 'utf8');
const model = {
  settings: { taxes: { gst: 18 } },
  rooms: [{ id: 'R101' }],
  guests: [{ id: 'G1' }],
  restaurantSales: [{ id: 'S1', total: 120 }],
};
const localStorage = {
  getItem: () => null,
  removeItem: () => { throw new Error('Bridge must never delete source browser storage'); },
  setItem: () => {},
};
const window = {
  DB: model,
  localStorage,
  dispatchEvent: () => {},
  addEventListener: () => {},
};
const context = { window, localStorage, DB: model, console, Date, JSON, Object, Array, Error, CustomEvent: function () {} };
vm.runInNewContext(source, context, { filename: 'native_migration_bridge.js' });

const payload = window.aureliaBuildMigrationPayload();
assert.equal(payload.app, 'Aurelia PMS');
assert.equal(payload.migrationProtocol, 1);
assert.equal(payload.data.rooms.length, 1);
assert.equal(payload.data.restaurantSales[0].total, 120);
assert.equal(payload.counts.rooms, 1);
assert.ok(Array.isArray(payload.storageKeys));

let intercepted = null;
window.MigrationChannel = { postMessage: (message) => { intercepted = JSON.parse(message); } };
assert.deepEqual(window.aureliaSendMigrationPayload(), { sent: true });
assert.equal(intercepted.data.guests[0].id, 'G1');

assert.equal(window.aureliaMigrationResult({ verified: true }), true);
assert.equal(window.aureliaMigrationResult({ verified: false }), false);
console.log('Native migration bridge smoke tests passed.');
