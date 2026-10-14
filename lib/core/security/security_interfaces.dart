import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

abstract interface class SecureStorageProvider {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

abstract interface class BiometricAuthProvider {
  Future<bool> isDeviceSupported();
  Future<bool> authenticate();
}

class FlutterSecureStorageProvider implements SecureStorageProvider {
  FlutterSecureStorageProvider(this.storage);
  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) => storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

class LocalBiometricAuthProvider implements BiometricAuthProvider {
  LocalBiometricAuthProvider(this.auth);
  final LocalAuthentication auth;

  @override
  Future<bool> isDeviceSupported() => auth.isDeviceSupported();

  @override
  Future<bool> authenticate() => auth.authenticate(
    localizedReason: 'Unlock Aurelia PMS',
    options: const AuthenticationOptions(
      stickyAuth: true,
      biometricOnly: false,
      useErrorDialogs: true,
    ),
  );
}
