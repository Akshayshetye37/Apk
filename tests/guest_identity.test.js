const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'assets', 'index.html'), 'utf8');
const start = html.lastIndexOf('function dedupeExistingGuestsInPlace(');
const end = html.indexOf('\nwindow.upsertGuestAndCascade', start);
assert.ok(start >= 0 && end > start, 'the final guest dedupe implementation must exist');

function guestCanonicalName(value) {
  return String(value || '').trim().toLowerCase().replace(/\s+/g, ' ');
}
function guestCanonicalIdNumber(value) {
  return String(value || '').trim().toUpperCase().replace(/\s+/g, '');
}

function runDedupe(database, preferredId) {
  const context = {
    DB: database,
    guestCanonicalName,
    guestCanonicalIdNumber,
  };
  vm.runInNewContext(
    html.slice(start, end) +
      '\nglobalThis.runDedupe = dedupeExistingGuestsInPlace;',
    context,
  );
  return context.runDedupe(preferredId);
}

test('editing a guest keeps its immutable ID and reassigns linked records', () => {
  const database = {
    guests: [
      {
        id: 'old-guest',
        name: 'Aditi Sharma',
        phone: '9876543210',
        idNumber: 'ABCDE1234F',
        idPhoto: 'data:image/jpeg;base64,old',
        occupants: [{ id: 'old-occupant' }],
        vehicles: [{ id: 'car-1' }],
      },
      {
        id: 'stable-guest',
        name: 'Aditi Sharma Updated',
        phone: '9876543210',
        idNumber: 'ABCDE1234F',
        idPhoto: 'data:image/jpeg;base64,new',
        occupants: [{ id: 'new-occupant' }],
        vehicles: [],
      },
    ],
    bookings: [{ id: 'booking-1', guestId: 'old-guest', guestName: 'Aditi Sharma' }],
    reservations: [{ id: 'reservation-1', guestId: 'old-guest', name: 'Aditi Sharma' }],
    folios: [{ id: 'folio-1', guestId: 'old-guest', phone: '9876543210' }],
    invoices: [],
    restaurantSales: [],
  };

  runDedupe(database, 'stable-guest');

  assert.equal(database.guests.length, 1);
  assert.equal(database.guests[0].id, 'stable-guest');
  assert.equal(database.guests[0].name, 'Aditi Sharma Updated');
  assert.equal(database.guests[0].idPhoto, 'data:image/jpeg;base64,new');
  assert.deepEqual(JSON.parse(JSON.stringify(database.guests[0].vehicles)), [{ id: 'car-1' }]);
  assert.equal(database.bookings[0].guestId, 'stable-guest');
  assert.equal(database.bookings[0].guestName, 'Aditi Sharma Updated');
  assert.equal(database.reservations[0].guestId, 'stable-guest');
  assert.equal(database.reservations[0].name, 'Aditi Sharma Updated');
  assert.equal(database.folios[0].guestId, 'stable-guest');
});

test('same name and phone with conflicting short ID numbers are not merged', () => {
  const database = {
    guests: [
      { id: 'guest-a', name: 'Ravi Kumar', phone: '9000000001', idNumber: '12345' },
      { id: 'guest-b', name: 'Ravi Kumar', phone: '9000000001', idNumber: '67890' },
    ],
    bookings: [],
    reservations: [],
    folios: [],
    invoices: [],
    restaurantSales: [],
  };

  runDedupe(database);
  assert.equal(database.guests.length, 2);
  assert.deepEqual(database.guests.map(g => g.id), ['guest-a', 'guest-b']);
});

test('same-name guests with different phone numbers are not merged', () => {
  const database = {
    guests: [
      { id: 'guest-a', name: 'Ravi Kumar', phone: '9000000001', idNumber: '' },
      { id: 'guest-b', name: 'Ravi Kumar', phone: '9000000002', idNumber: '' },
    ],
    bookings: [],
    reservations: [],
    folios: [],
    invoices: [],
    restaurantSales: [],
  };

  runDedupe(database);
  assert.equal(database.guests.length, 2);
  assert.equal(database.guests[0].id, 'guest-a');
  assert.equal(database.guests[1].id, 'guest-b');
});
