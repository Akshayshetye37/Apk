import 'package:aurelia_pms/core/security/pin_kdf_service.dart';
import 'package:aurelia_pms/core/security/security_interfaces.dart';
import 'package:aurelia_pms/main.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryStorage implements SecureStorageProvider {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class FakeAuth implements BiometricAuthProvider {
  FakeAuth({this.supported = false, this.result = false});
  final bool supported;
  final bool result;
  @override
  Future<bool> isDeviceSupported() async => supported;
  @override
  Future<bool> authenticate() async => result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PIN service provisions and verifies Argon2id payload', () async {
    final storage = MemoryStorage();
    final service = PinKdfService(storage);
    expect(await service.checkProvisioningState(), PinProvisioningState.notProvisioned);
    await service.provisionPin('123456');
    expect(await service.checkProvisioningState(), PinProvisioningState.provisioned);
    expect(await service.verifyPin('123456'), PinVerificationResult.success);
    expect(await service.verifyPin('000000'), PinVerificationResult.incorrect);
    expect(storage.values[PinKdfService.failedKey], '1');
  });

  test('malformed payload fails closed and is never treated as a PIN match', () async {
    final storage = MemoryStorage()
      ..values[PinKdfService.payloadKey] = '{"v":1,"salt":"AA==","hash":"AA==","mem":999999999,"ops":2,"parallelism":1}';
    final service = PinKdfService(storage);
    expect(
      () => service.checkProvisioningState(),
      throwsFormatException,
    );
    expect(await service.verifyPin('123456'), PinVerificationResult.invalidPayload);
  });

  test('three failures persist lockout and block further verification', () async {
    final storage = MemoryStorage();
    final service = PinKdfService(storage);
    await service.provisionPin('123456');
    expect(await service.verifyPin('000000'), PinVerificationResult.incorrect);
    expect(await service.verifyPin('000000'), PinVerificationResult.incorrect);
    expect(await service.verifyPin('000000'), PinVerificationResult.lockedOut);
    expect(storage.values[PinKdfService.untilKey], isNotNull);
    expect(await service.verifyPin('123456'), PinVerificationResult.lockedOut);
  });

  test('legacy hash is verified before migration and retained on failure', () async {
    final storage = MemoryStorage();
    var bytes = 'aurelia-salt:123456'.codeUnits;
    // Match the legacy implementation exactly: 100,000 chained SHA-256 rounds.
    var digest = bytes;
    for (var i = 0; i < 100000; i++) {
      digest = sha256.convert(digest).bytes;
    }
    storage.values[PinKdfService.legacySaltKey] = 'aurelia-salt';
    storage.values[PinKdfService.legacyHashKey] = base64UrlEncode(digest);
    final service = PinKdfService(storage);
    expect(await service.checkProvisioningState(), PinProvisioningState.requiresMigration);
    expect(await service.verifyPin('000000'), PinVerificationResult.incorrect);
    expect(storage.values[PinKdfService.legacyHashKey], isNotNull);
    expect(await service.verifyPin('123456'), PinVerificationResult.success);
    expect(storage.values[PinKdfService.legacyHashKey], isNull);
    expect(storage.values[PinKdfService.payloadKey], isNotNull);
  });

  testWidgets('gate obscures dashboard, provisions, and relocks on pause', (tester) async {
    final storage = MemoryStorage();
    await tester.pumpWidget(MaterialApp(
      home: AureliaSecurityGate(
        storage: storage,
        auth: FakeAuth(),
        child: const Scaffold(body: Text('PMS Dashboard')),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Create your Aurelia PIN'), findsOneWidget);
    expect(find.text('PMS Dashboard').hitTestable(), findsNothing);

    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.text('Save PIN'));
    // PIN derivation runs asynchronously; allow the KDF future to complete
    // before asserting that the gate has revealed its child.
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!storage.values.containsKey(PinKdfService.payloadKey) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!storage.values.containsKey(PinKdfService.payloadKey)) {
        throw StateError('PIN provisioning did not finish within 30 seconds.');
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('PMS Dashboard').hitTestable(), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text('PMS Dashboard').hitTestable(), findsNothing);
    expect(find.text('Unlock Aurelia PMS'), findsOneWidget);
  });
}
