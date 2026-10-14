import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'security_interfaces.dart';

enum PinProvisioningState {
  notProvisioned,
  provisioned,
  requiresMigration,
  lockedOut,
}

enum PinVerificationResult {
  success,
  incorrect,
  lockedOut,
  notProvisioned,
  invalidPayload,
}

class PinKdfService {
  PinKdfService(this.storage, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final SecureStorageProvider storage;
  final DateTime Function() _clock;
  final Argon2id _kdf =
      Argon2id(memory: 19456, iterations: 2, parallelism: 1, hashLength: 32);

  static const payloadKey = 'aurelia_pin_payload';
  static const legacyHashKey = 'aurelia_pin_hash_v1';
  static const legacySaltKey = 'aurelia_pin_salt_v1';
  static const failedKey = 'aurelia_pin_failed_v1';
  static const untilKey = 'aurelia_pin_lockout_until_v1';

  Future<PinProvisioningState> checkProvisioningState() async {
    if (await _activeLockout() != null) return PinProvisioningState.lockedOut;
    final payload = await storage.read(payloadKey);
    if (payload != null) {
      _parsePayload(payload); // Fail closed for malformed stored metadata.
      return PinProvisioningState.provisioned;
    }
    if (await storage.read(legacyHashKey) != null &&
        await storage.read(legacySaltKey) != null) {
      return PinProvisioningState.requiresMigration;
    }
    return PinProvisioningState.notProvisioned;
  }

  Future<void> provisionPin(String pin) async {
    _validatePin(pin);
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final key = await _kdf.deriveKeyFromPassword(password: pin, nonce: salt);
    final hash = await key.extractBytes();
    final payload = jsonEncode({
      'v': 1,
      'salt': base64Encode(salt),
      'hash': base64Encode(hash),
      'mem': 19456,
      'ops': 2,
      'parallelism': 1,
    });
    // Write first and read back before deleting any legacy credential.
    await storage.write(payloadKey, payload);
    final written = await storage.read(payloadKey);
    if (written == null || !_constantTimeEquals(
      _parsePayload(written).hash,
      hash,
    )) {
      throw StateError('PIN payload read-back verification failed.');
    }
    await storage.delete(legacyHashKey);
    await storage.delete(legacySaltKey);
    await _clearFailures();
  }

  Future<PinVerificationResult> verifyPin(String input) async {
    if (await _activeLockout() != null) return PinVerificationResult.lockedOut;
    if (!RegExp(r'^\d{6,12}$').hasMatch(input)) {
      return _recordFailure();
    }

    final payloadString = await storage.read(payloadKey);
    if (payloadString != null) {
      try {
        final parsed = _parsePayload(payloadString);
        final key = await _kdf.deriveKeyFromPassword(
          password: input,
          nonce: parsed.salt,
        );
        final actual = await key.extractBytes();
        if (_constantTimeEquals(actual, parsed.hash)) {
          await _clearFailures();
          return PinVerificationResult.success;
        }
        return _recordFailure();
      } on FormatException {
        return PinVerificationResult.invalidPayload;
      } on TypeError {
        return PinVerificationResult.invalidPayload;
      }
    }

    // Existing app hashes salt + ':' + PIN, then applies 100,000 SHA-256
    // rounds. Verify that exact format before upgrading; never discard it first.
    final oldHash = await storage.read(legacyHashKey);
    final oldSalt = await storage.read(legacySaltKey);
    if (oldHash == null || oldSalt == null) {
      return PinVerificationResult.notProvisioned;
    }
    final matches = _verifyLegacy(oldSalt, input, oldHash);
    if (!matches) return _recordFailure();
    await provisionPin(input);
    return PinVerificationResult.success;
  }

  Future<DateTime?> _activeLockout() async {
    final raw = await storage.read(untilKey);
    if (raw == null) return null;
    final millis = int.tryParse(raw);
    if (millis == null) {
      await storage.delete(untilKey);
      return null;
    }
    final until = DateTime.fromMillisecondsSinceEpoch(millis);
    if (!_clock().isBefore(until)) {
      await storage.delete(untilKey);
      return null;
    }
    return until;
  }

  Future<PinVerificationResult> _recordFailure() async {
    final current = int.tryParse(await storage.read(failedKey) ?? '') ?? 0;
    final attempts = (current + 1).clamp(1, 1000000);
    await storage.write(failedKey, attempts.toString());
    if (attempts >= 3) {
      final duration = attempts < 6
          ? const Duration(minutes: 5)
          : const Duration(minutes: 30);
      await storage.write(
        untilKey,
        _clock().add(duration).millisecondsSinceEpoch.toString(),
      );
      return PinVerificationResult.lockedOut;
    }
    return PinVerificationResult.incorrect;
  }

  Future<void> _clearFailures() async {
    await storage.write(failedKey, '0');
    await storage.delete(untilKey);
  }

  bool _verifyLegacy(String salt, String pin, String expected) {
    List<int> bytes = utf8.encode('$salt:$pin');
    for (var i = 0; i < 100000; i++) {
      bytes = sha256.convert(bytes).bytes;
    }
    final actual = base64UrlEncode(bytes);
    return _constantTimeStringEquals(actual, expected);
  }

  _PinPayload _parsePayload(String source) {
    if (source.length > 2048) throw const FormatException('Payload too large.');
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.toSet().difference(
          {'v', 'salt', 'hash', 'mem', 'ops', 'parallelism'},
        ).isNotEmpty ||
        decoded['v'] != 1 ||
        decoded['mem'] != 19456 ||
        decoded['ops'] != 2 ||
        decoded['parallelism'] != 1 ||
        decoded['salt'] is! String ||
        decoded['hash'] is! String) {
      throw const FormatException('Invalid PIN payload schema or parameters.');
    }
    final salt = base64Decode(decoded['salt'] as String);
    final hash = base64Decode(decoded['hash'] as String);
    if (salt.length != 16 || hash.length != 32) {
      throw const FormatException('Invalid PIN payload lengths.');
    }
    return _PinPayload(salt, hash);
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  bool _constantTimeStringEquals(String a, String b) {
    final aa = utf8.encode(a);
    final bb = utf8.encode(b);
    return _constantTimeEquals(aa, bb);
  }

  void _validatePin(String pin) {
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin)) {
      throw ArgumentError('PIN must contain 6–12 digits.');
    }
  }
}

class _PinPayload {
  const _PinPayload(this.salt, this.hash);
  final List<int> salt;
  final List<int> hash;
}
