const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function createHarness(options = {}) {
  const listeners = {};
  const documentListeners = {};
  const messages = [];
  let lastReader;
  let reloads = 0;
  let saves = 0;
  const postedMessages = [];
  const promptAnswers = [...(options.promptAnswers || [])];
  const window = {
    prompt: () => promptAnswers.length ? promptAnswers.shift() : null,
    AureliaNative: options.native ? { postMessage: message => postedMessages.push(JSON.parse(message)) } : undefined,
    __AURELIA_SECURE_DB_READY: !!options.native,
    DB: options.db || { guests: [{ id: 'old' }], rooms: [], bookings: [], obsolete: ['remove me'] },
    restaurantSelectedBooking: options.selectedBooking || '',
    commitRestaurant: options.commitRestaurant,
    toast: message => messages.push(message),
    confirm: () => options.confirm !== false,
    addEventListener: (name, fn) => { listeners[name] = fn; },
    location: { reload: () => { reloads += 1; } },
    save: async function () {
      saves += 1;
      if (options.saveFails && saves === 1) throw new Error('simulated save failure');
    }
  };
  const document = {
    addEventListener: (name, fn) => { documentListeners[name] = fn; },
    getElementById: () => null,
    createElement: () => ({ style: {}, click() {}, remove() {} }),
    body: { appendChild() {} }
  };
  class FakeFileReader {
    readAsText(file) {
      this.result = file.content;
      lastReader = this;
      this.done = Promise.resolve().then(() => this.onload && this.onload());
    }
  }
  const context = {
    window, document, navigator: {}, console, FileReader: FakeFileReader, Blob,
    URL: { createObjectURL: () => 'blob:test', revokeObjectURL() {} },
    DB: window.DB, restaurantSelectedBooking: options.selectedBooking || '',
    setTimeout: () => 0, Date, JSON, Object, Array, Number, String, RegExp, Set, Promise
  };
  vm.runInNewContext(fs.readFileSync('scripts/interaction_reliability.js', 'utf8'), context);
  return {
    window, messages, postedMessages,
    commitRestaurant(mode) { if (typeof window.commitRestaurant === 'function') return window.commitRestaurant(mode); },
    async importJson(content) {
      window.aureliaImportBackupFile({ size: Buffer.byteLength(content), content });
      await lastReader.done;
    },
    get reloads() { return reloads; },
    get saves() { return saves; }
  };
}

test('rejects incomplete backups without mutating current records', async () => {
  const app = createHarness();
  const before = JSON.stringify(app.window.DB);
  await app.importJson(JSON.stringify({ data: { guests: [{ id: 'new' }] }, app: 'AURELIA PMS', formatVersion: 1 }));
  assert.equal(JSON.stringify(app.window.DB), before);
  assert.match(app.messages.at(-1), /missing the required "rooms" list/);
  assert.equal(app.saves, 0);
});

test('rejects prototype-pollution keys before changing records', async () => {
  const app = createHarness();
  const before = JSON.stringify(app.window.DB);
  const malicious = JSON.parse('{"app":"AURELIA PMS","formatVersion":1,"data":{"guests":[],"rooms":[],"bookings":[],"settings":{"__proto__":{"polluted":true}}}}');
  await app.importJson(JSON.stringify(malicious));
  assert.equal(JSON.stringify(app.window.DB), before);
  assert.equal({}.polluted, undefined);
  assert.match(app.messages.at(-1), /unsafe property name/);
});

test('valid backup replaces the database and removes stale keys', async () => {
  const app = createHarness();
  await app.importJson(JSON.stringify({
    app: 'AURELIA PMS', formatVersion: 1,
    data: { guests: [{ id: 'new' }], rooms: [{ id: 'r1' }], bookings: [] }
  }));
  assert.deepEqual(JSON.parse(JSON.stringify(app.window.DB)), {
    guests: [{ id: 'new' }], rooms: [{ id: 'r1' }], bookings: []
  });
  assert.equal(app.saves, 1);
  assert.match(app.messages.at(-1), /imported and saved/);
});

test('rolls in-memory data back if saving the restore fails', async () => {
  const app = createHarness({ saveFails: true });
  const before = JSON.stringify(app.window.DB);
  await app.importJson(JSON.stringify({
    app: 'AURELIA PMS', formatVersion: 1,
    data: { guests: [], rooms: [], bookings: [] }
  }));
  assert.equal(JSON.stringify(app.window.DB), before);
  assert.match(app.messages.at(-1), /previous in-memory data was restored/);
});

test('Android backup export requests passphrase-encrypted native output', () => {
  const app = createHarness({ native: true, promptAnswers: ['correct horse battery staple', 'correct horse battery staple'] });
  app.window.aureliaDownloadBackup();
  assert.equal(app.postedMessages.length, 1);
  assert.equal(app.postedMessages[0].type, 'exportEncryptedBackup');
  assert.equal(app.postedMessages[0].passphrase, 'correct horse battery staple');
  assert.equal(typeof app.postedMessages[0].data, 'string');
});

test('encrypted backup import is delegated to native decrypt-and-validate flow', async () => {
  const app = createHarness({ native: true, promptAnswers: ['correct horse battery staple'] });
  const envelope = {
    app: 'AURELIA PMS ENCRYPTED BACKUP', formatVersion: 1,
    kdf: 'PBKDF2-HMAC-SHA256', iterations: 310000, algorithm: 'AES-256-GCM',
    salt: 'AAAAAAAAAAAAAAAAAAAAAA==', nonce: 'AAAAAAAAAAAAAAAA', ciphertext: '', tag: 'AAAAAAAAAAAAAAAAAAAAAA=='
  };
  await app.importJson(JSON.stringify(envelope));
  assert.equal(app.postedMessages.length, 1);
  assert.equal(app.postedMessages[0].type, 'restoreEncryptedBackup');
  assert.equal(app.postedMessages[0].envelope.app, 'AURELIA PMS ENCRYPTED BACKUP');
});

test('room billing requires an active stay and valid room', () => {
  let commits = 0;
  const app = createHarness({
    selectedBooking: 'b1',
    commitRestaurant: () => { commits += 1; },
    db: {
      restaurantCart: [{ itemId: 'food1', name: 'Curry', price: 1, qty: 1 }],
      madeFoods: [{ id: 'food1', name: 'Chicken Curry', sell: 180, unit: 'plate', active: true }],
      bookings: [{ id: 'b1', roomId: 'r1', status: 'checked_out' }],
      rooms: [{ id: 'r1', number: '101', status: 'available' }]
    }
  });
  app.commitRestaurant('room');
  assert.equal(commits, 0);
  assert.match(app.messages.at(-1), /active checked-in guest/);
});

test('room billing canonicalizes prices and rejects non-menu items', () => {
  let committedMode = '';
  let committedCart = null;
  let commitCount = 0;
  const app = createHarness({
    selectedBooking: 'b1',
    commitRestaurant: mode => { commitCount += 1; committedMode = mode; committedCart = JSON.parse(JSON.stringify(appDb.restaurantCart)); },
    db: {
      restaurantCart: [{ itemId: 'food1', name: 'Forged name', price: 1, qty: 2 }],
      madeFoods: [{ id: 'food1', name: 'Chicken Curry', sell: 180, unit: 'plate', active: true }],
      bookings: [{ id: 'b1', roomId: 'r1', status: 'active' }],
      rooms: [{ id: 'r1', number: '101', status: 'occupied' }]
    }
  });
  const appDb = app.window.DB;
  app.commitRestaurant('room');
  assert.equal(committedMode, 'room');
  assert.equal(commitCount, 1);
  assert.deepEqual(committedCart, [{ itemId: 'food1', name: 'Chicken Curry', unit: 'plate', price: 180, qty: 2 }]);
  appDb.restaurantCart[0].itemId = 'hotel-room-charge';
  app.commitRestaurant('room');
  assert.equal(commitCount, 1);
  assert.match(app.messages.at(-1), /Only active restaurant menu items/);
});

test('Android plaintext restore reboots through secure native storage instead of WebView reload', async () => {
  const app = createHarness({
    native: true,
    db: { guests: [{ id: 'old' }], rooms: [], bookings: [] }
  });
  await app.importJson(JSON.stringify({
    app: 'AURELIA PMS',
    formatVersion: 1,
    data: { guests: [{ id: 'restored' }], rooms: [], bookings: [] }
  }));
  assert.equal(app.postedMessages.length, 1);
  assert.equal(app.postedMessages[0].type, 'reloadSecurePms');
  assert.equal(app.reloads, 0);
  assert.equal(app.saves, 1);
});
