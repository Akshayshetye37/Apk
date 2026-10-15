import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import '../lib/main.dart' show AureliaEncryptedPmsStore;

Map<String, dynamic> validPayload() => {
  'app': 'AURELIA PMS',
  'formatVersion': 1,
  'exportedAt': '2026-10-15T00:00:00.000Z',
  'data': {
    'guests': [{'id': 'g1', 'name': 'Secret Guest'}],
    'rooms': [{'id': 'r1', 'name': 'Room 1'}],
    'bookings': [],
    'reservations': [],
    'expenses': [],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('portable backup encrypts guest data and restores with the right passphrase', () async {
    final payload = jsonEncode(validPayload());
    final envelope = await AureliaEncryptedPmsStore.encryptPortableBackup(
      payload,
      'correct horse battery staple',
    );

    expect(envelope, contains('AURELIA PMS ENCRYPTED BACKUP'));
    expect(envelope, isNot(contains('Secret Guest')));

    final restored = await AureliaEncryptedPmsStore.decryptPortableBackup(
      envelope,
      'correct horse battery staple',
    );
    expect(jsonDecode(restored), equals(validPayload()['data']));
  });

  test('wrong passphrase cannot decrypt the backup', () async {
    final envelope = await AureliaEncryptedPmsStore.encryptPortableBackup(
      jsonEncode(validPayload()),
      'correct horse battery staple',
    );
    await expectLater(
      AureliaEncryptedPmsStore.decryptPortableBackup(envelope, 'wrong passphrase'),
      throwsA(anything),
    );
  });

  test('tampered authentication tag is rejected', () async {
    final envelope = jsonDecode(await AureliaEncryptedPmsStore.encryptPortableBackup(
      jsonEncode(validPayload()),
      'correct horse battery staple',
    )) as Map<String, dynamic>;
    envelope['tag'] = base64Encode(List<int>.filled(16, 0));
    await expectLater(
      AureliaEncryptedPmsStore.decryptPortableBackup(jsonEncode(envelope), 'correct horse battery staple'),
      throwsA(anything),
    );
  });

  test('backup missing required booking data is rejected before encryption', () async {
    final payload = validPayload();
    (payload['data'] as Map<String, dynamic>).remove('bookings');
    (payload['data'] as Map<String, dynamic>).remove('reservations');
    await expectLater(
      AureliaEncryptedPmsStore.encryptPortableBackup(jsonEncode(payload), 'correct horse battery staple'),
      throwsA(anything),
    );
  });

  test('short passphrases are rejected', () async {
    await expectLater(
      AureliaEncryptedPmsStore.encryptPortableBackup(jsonEncode(validPayload()), '12345'),
      throwsA(anything),
    );
  });
}

test('duplicate record IDs are rejected before encryption', () async {
  final payload = validPayload();
  final data = payload['data'] as Map<String, dynamic>;
  (data['guests'] as List).add({'id': 'g1', 'name': 'Duplicate'});
  await expectLater(
    AureliaEncryptedPmsStore.encryptPortableBackup(jsonEncode(payload), 'correct horse battery staple'),
    throwsA(anything),
  );
});

test('non-object records are rejected before encryption', () async {
  final payload = validPayload();
  final data = payload['data'] as Map<String, dynamic>;
  data['rooms'] = ['not a room record'];
  await expectLater(
    AureliaEncryptedPmsStore.encryptPortableBackup(jsonEncode(payload), 'correct horse battery staple'),
    throwsA(anything),
  );
});
