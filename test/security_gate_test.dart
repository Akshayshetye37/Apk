import 'dart:convert';

import 'package:aurelia_pms/core/security/pin_kdf_service.dart';
import 'package:aurelia_pms/core/security/security_interfaces.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryStorage implements SecureStorageProvider {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PIN service provisions and verifies Argon2id payload', () async {
    final storage = MemoryStorage();
    final service = PinKdfService(storage);

    expect(
      await service.checkProvisioningState(),
      PinProvisioningState.notProvisioned,
    );
    await service.provisionPin('123456');
    expect(
      await service.checkProvisioningState(),
      PinProvisioningState.provisioned,
    );
    expect(await service.verifyPin('123456'), PinVerificationResult.success);
    expect(await service.verifyPin('000000'), PinVerificationResult.incorrect);
    expect(storage.values[PinKdfService.failedKey], '1');
  });

  test('malformed payload fails closed', () async {
    final storage = MemoryStorage()
      ..values[PinKdfService.payloadKey] =
          '{"v":1,"salt":"AA==","hash":"AA==","mem":999999999,"ops":2,"parallelism":1}';
    final service = PinKdfService(storage);

    expect(
      await service.checkProvisioningState(),
      throwsFormatException,
    );
    expect(
      await service.verifyPin('123456'),
      PinVerificationResult.invalidPayload,
    );
  });

  test('three incorrect PIN attempts persist lockout', () async {
    final storage = MemoryStorage();
    final service = PinKdfService(storage);

    await service.provisionPin('123456');
    expect(await service.verifyPin('000000'), PinVerificationResult.incorrect);
    expect(await service.verifyPin('000000'), PinVerificationResult.incorrect);
    expect(await service.verifyPin('000000'), PinVerificationResult.lockedOut);
    expect(storage.values[PinKdfService.untilKey], isNotNull);
    expect(await service.verifyPin('123456'), PinVerificationResult.lockedOut);
  });

  test('legacy PIN hash is retained until successful verification', () async {
    final storage = MemoryStorage();
    List<int> digest = utf8.encode('aurelia-salt:123456');
    for (var i = 0; i < 100000; i++) {
      digest = sha256.convert(digest).bytes;
    }
    storage.values[PinKdfService.legacySaltKey] = 'aurelia-salt';
    storage.values[PinKdfService.legacyHashKey] = base64UrlEncode(digest);
    final service = PinKdfService(storage);

    expect(
      await service.checkProvisioningState(),
      PinProvisioningState.requiresMigration,
    );
    expect(await service.verifyPin('000000'), PinVerificationResult.incorrect);
    expect(storage.values[PinKdfService.legacyHashKey], isNotNull);
    expect(await service.verifyPin('123456'), PinVerificationResult.success);
    expect(storage.values[PinKdfService.legacyHashKey], isNull);
    expect(storage.values[PinKdfService.payloadKey], isNotNull);
  });
}
