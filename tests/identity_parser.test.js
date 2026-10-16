const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'assets', 'index.html'), 'utf8');
const start = html.indexOf('function parseIdText(text){');
const end = html.indexOf('\nlet pendingBookingIdPhoto', start);
assert.ok(start >= 0 && end > start, 'parseIdText must remain available in the bundled app');
const context = {};
vm.runInNewContext(html.slice(start, end) + '\nglobalThis.parseIdText = parseIdText;', context);
const parseIdText = context.parseIdText;

test('PAN card number and labelled name are extracted without government headers', () => {
  const result = parseIdText('INCOME TAX DEPARTMENT\nPermanent Account Number\nName: Aditi Sharma\nPAN: ABCDE1234F\nDOB: 14/08/1990');
  assert.equal(result.idType, 'PAN Card');
  assert.equal(result.idNumber, 'ABCDE1234F');
  assert.equal(result.name, 'Aditi Sharma');
});

test('Aadhaar headers are not mistaken for a guest name', () => {
  const result = parseIdText('Government of India\nUnique Identification Authority of India\nAadhaar Card\nRAVI KUMAR\nDate of Birth: 02/03/1988\n2345 6789 1234');
  assert.equal(result.idType, 'Aadhaar Card');
  assert.equal(result.idNumber, '2345 6789 1234');
  assert.equal(result.name, 'Ravi Kumar');
});

test('passport MRZ supplies document number and holder name', () => {
  const result = parseIdText('P<INDL12345678<IND<<<<<<<<<<<<<<<<<<<<\nKUMAR<<RAHUL<<<<<<<<<<<<<<<<<<<<');
  assert.equal(result.idType, 'Passport');
  assert.equal(result.idNumber, 'L12345678');
  assert.equal(result.name, 'Rahul Kumar');
});

test('Indian driving licence and voter ID formats are recognized', () => {
  const dl = parseIdText('Driving Licence\nMH1420110061234\nName: Priya Nair');
  const voter = parseIdText('Election Commission of India\nName: Amit Shah\nABC1234567');
  assert.equal(dl.idType, 'Driving Licence');
  assert.equal(dl.idNumber.replace(/\s/g, ''), 'MH1420110061234');
  assert.equal(voter.idType, 'Voter ID');
  assert.equal(voter.idNumber, 'ABC1234567');
});

test('government headers alone do not produce a false person name', () => {
  const result = parseIdText('Government of India\nUnique Identification Authority of India\nINCOME TAX DEPARTMENT\nPERMANENT ACCOUNT NUMBER');
  assert.equal(result.name, '');
});
