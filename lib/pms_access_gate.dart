import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

typedef SecretReader = Future<String?> Function(String key);
typedef SecretWriter = Future<void> Function(String key, String value);
typedef SecretDeleter = Future<void> Function(String key);

class PmsAccessGate extends StatefulWidget {
  const PmsAccessGate({
    super.key,
    required this.readSecret,
    required this.writeSecret,
    required this.deleteSecret,
    required this.onUnlocked,
  });

  final SecretReader readSecret;
  final SecretWriter writeSecret;
  final SecretDeleter deleteSecret;
  final Future<void> Function() onUnlocked;

  @override
  State<PmsAccessGate> createState() => _PmsAccessGateState();
}

class _PmsAccessGateState extends State<PmsAccessGate> {
  static const String _saltKey = 'aurelia_pms_pin_salt_v1';
  static const String _hashKey = 'aurelia_pms_pin_hash_v1';
  static const String _attemptsKey = 'aurelia_pms_pin_attempts_v1';
  static const String _lockUntilKey = 'aurelia_pms_pin_lock_until_v1';
  static const String _recoverySaltKey = 'aurelia_pms_recovery_salt_v1';
  static const String _recoveryHashKey = 'aurelia_pms_recovery_hash_v1';

  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _recoveryCode = TextEditingController();
  final LocalAuthentication _localAuth = LocalAuthentication();
  final Pbkdf2 _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 310000,
    bits: 256,
  );

  bool _loading = true;
  bool _configured = false;
  bool _busy = false;
  bool _deviceAuthAvailable = false;
  bool _biometricEnabled = false;
  bool _pinEntryEnabled = false;
  bool _recoveryMode = false;
  int _failedAttempts = 0;
  DateTime? _lockUntil;
  String? _error;
  Timer? _lockoutTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final biometricPreference = await widget.readSecret('aurelia_pms_biometric_enabled_v1');
      final pinEntryPreference = await widget.readSecret('aurelia_pms_pin_entry_enabled_v1');
      // Authentication is opt-in. If neither method is enabled, do not
      // force first-run PIN creation; users can enable either method in Settings.
      // An explicit legacy "false" protection value also remains a bypass.
      if (pinEntryPreference != 'true' && biometricPreference != 'true') {
        if (!mounted) return;
        setState(() { _loading = false; _configured = false; });
        await widget.onUnlocked();
        return;
      }
      final salt = await widget.readSecret(_saltKey);
      final hash = await widget.readSecret(_hashKey);
      if ((salt == null) != (hash == null)) {
        throw StateError('PIN configuration is incomplete. Existing encrypted PMS data has not been changed.');
      }
      final attempts = await widget.readSecret(_attemptsKey);
      final lock = await widget.readSecret(_lockUntilKey);
      var deviceAuth = false;
      try {
        deviceAuth = await _localAuth.isDeviceSupported();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _configured = salt != null && hash != null;
        _failedAttempts = int.tryParse(attempts ?? '') ?? 0;
        _lockUntil = lock == null ? null : DateTime.tryParse(lock);
        _deviceAuthAvailable = deviceAuth;
        _biometricEnabled = biometricPreference == 'true' && deviceAuth;
        _pinEntryEnabled = pinEntryPreference == 'true' ||
            (biometricPreference == 'true' && !deviceAuth);
        _loading = false;
      });
      _startLockoutTicker();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Secure authentication could not be loaded. Do not clear app data or reinstall. $error';
      });
    }
  }

  Future<List<int>> _deriveHash(String pin, List<int> salt) async {
    final key = await _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return key.extractBytes();
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  Future<String?> _ensureRecoveryCode() async {
    final existingSalt = await widget.readSecret(_recoverySaltKey);
    final existingHash = await widget.readSecret(_recoveryHashKey);
    if (existingSalt != null && existingHash != null) return null;
    if ((existingSalt == null) != (existingHash == null)) {
      throw StateError('Recovery configuration is incomplete. Existing PMS data has not been changed.');
    }
    final random = math.Random.secure();
    final code = List<int>.generate(16, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final hash = await _deriveHash(code, salt);
    await widget.writeSecret(_recoverySaltKey, base64Encode(salt));
    await widget.writeSecret(_recoveryHashKey, base64Encode(hash));
    return code;
  }

  Future<void> _showRecoveryCodeIfCreated(String? code) async {
    if (code == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save your recovery code'),
        content: SelectableText('$code\n\nKeep this code private and separate from this device. It is shown only once and can reset your PMS PIN.'),
        actions: [
          TextButton(onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (dialogContext.mounted) ScaffoldMessenger.of(dialogContext).showSnackBar(const SnackBar(content: Text('Recovery code copied')));
          }, child: const Text('Copy code')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('I saved it')),
        ],
      ),
    );
  }

  Future<void> _verifyRecoveryCode() async {
    setState(() { _busy = true; _error = null; });
    try {
      final saltValue = await widget.readSecret(_recoverySaltKey);
      final hashValue = await widget.readSecret(_recoveryHashKey);
      if (saltValue == null || hashValue == null) throw StateError('No recovery code is configured. If you still have access, unlock with your PIN to create one.');
      final value = _recoveryCode.text.trim().replaceAll(RegExp(r'\\s+'), '').toUpperCase();
      if (value.length != 32 || !RegExp(r'^[0-9A-F]{32}
    final value = _pin.text;
    if (!RegExp(r'^[0-9]{6,12}$').hasMatch(value)) {
      setState(() => _error = 'Choose a PIN with 6 to 12 digits.');
      return;
    }
    if (value != _confirm.text) {
      setState(() => _error = 'The PINs do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final random = math.Random.secure();
      final salt = List<int>.generate(16, (_) => random.nextInt(256));
      final hash = await _deriveHash(value, salt);
      await widget.writeSecret(_saltKey, base64Encode(salt));
      await widget.writeSecret(_hashKey, base64Encode(hash));
      await widget.writeSecret(_attemptsKey, '0');
      await widget.deleteSecret(_lockUntilKey);
      final recoveryCode = await _ensureRecoveryCode();
      if (!mounted) return;
      _pin.clear();
      _confirm.clear();
      await _showRecoveryCodeIfCreated(recoveryCode);
      await widget.onUnlocked();
    } catch (error) {
      try {
        await widget.deleteSecret(_saltKey);
        await widget.deleteSecret(_hashKey);
      } catch (_) {}
      if (mounted) setState(() => _error = 'Could not securely save the PIN. Try again. $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyPin() async {
    final now = DateTime.now();
    if (_lockUntil != null && now.isBefore(_lockUntil!)) {
      setState(() => _error = 'Too many attempts. Try again after ${_lockUntil!.toLocal()}.');
      return;
    }
    if (_lockUntil != null && !now.isBefore(_lockUntil!)) {
      _failedAttempts = 0;
      _lockUntil = null;
      await widget.writeSecret(_attemptsKey, '0');
      await widget.deleteSecret(_lockUntilKey);
    }
    final value = _pin.text;
    if (!RegExp(r'^[0-9]{6,12}$').hasMatch(value)) {
      setState(() => _error = 'Enter your 6 to 12 digit PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saltValue = await widget.readSecret(_saltKey);
      final hashValue = await widget.readSecret(_hashKey);
      if (saltValue == null || hashValue == null) throw StateError('PIN configuration is missing.');
      final candidate = await _deriveHash(value, base64Decode(saltValue));
      final expected = base64Decode(hashValue);
      if (_constantTimeEquals(candidate, expected)) {
        await widget.writeSecret(_attemptsKey, '0');
        await widget.deleteSecret(_lockUntilKey);
        _failedAttempts = 0;
        _lockUntil = null;
        _pin.clear();
        final recoveryCode = await _ensureRecoveryCode();
        await _showRecoveryCodeIfCreated(recoveryCode);
        await widget.onUnlocked();
        return;
      }
      _failedAttempts += 1;
      await widget.writeSecret(_attemptsKey, _failedAttempts.toString());
      if (_failedAttempts >= 5) {
        _lockUntil = DateTime.now().add(const Duration(minutes: 5));
        await widget.writeSecret(_lockUntilKey, _lockUntil!.toIso8601String());
        _startLockoutTicker();
      }
      if (mounted) {
        setState(() {
          _error = _lockUntil == null
              ? 'Incorrect PIN. ${5 - _failedAttempts} attempts remain before a 5-minute lockout.'
              : 'Too many attempts. Access is locked for 5 minutes.';
        });
      }
      _pin.clear();
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not verify PIN securely. $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startLockoutTicker() {
    _lockoutTimer?.cancel();
    if (_lockUntil == null) return;
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lockUntil == null || !DateTime.now().isBefore(_lockUntil!)) {
        timer.cancel();
        setState(() {
          _lockUntil = null;
          _failedAttempts = 0;
          _error = null;
        });
        unawaited(widget.writeSecret(_attemptsKey, '0'));
        unawaited(widget.deleteSecret(_lockUntilKey));
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _tryDeviceAuthentication() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Unlock Aurelia PMS',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      if (!mounted) return;
      if (authenticated) {
        await widget.writeSecret(_attemptsKey, '0');
        await widget.deleteSecret(_lockUntilKey);
        _failedAttempts = 0;
        _lockUntil = null;
        await widget.onUnlocked();
      } else {
        setState(() => _error = 'Device authentication was cancelled or not accepted.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Device authentication is unavailable. Use your PIN. $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    _pin.dispose();
    _confirm.dispose();
    _recoveryCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockUntil != null && DateTime.now().isBefore(_lockUntil!);
    final remaining = locked ? _lockUntil!.difference(DateTime.now()).inSeconds + 1 : 0;
    return Container(
      color: const Color(0xFFF3F7FA),
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    _loading ? 'Securing Aurelia PMS' : (_configured || !_pinEntryEnabled ? 'Unlock Aurelia PMS' : 'Create your PMS PIN'),
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your PMS data is encrypted on this device. Keep your PIN private and keep an encrypted backup somewhere safe.',
                    textAlign: TextAlign.center,
                  ),
                  if (_loading) const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(),
                  ),
                  if (!_loading && _error != null) Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                  ),
                  if (!_loading && !_configured && _pinEntryEnabled && _error == null) const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Choose 6–12 digits. This PIN is not recoverable by the developer; store it safely.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (!_loading && _error == null) ...[
                    const SizedBox(height: 16),
                    if (_recoveryMode) ...[
                      TextField(controller: _recoveryCode, textCapitalization: TextCapitalization.characters, autocorrect: false, enableSuggestions: false, maxLength: 32, enabled: !_busy, decoration: const InputDecoration(labelText: 'Recovery code', border: OutlineInputBorder()), onSubmitted: (_) => _verifyRecoveryCode()),
                      SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : _verifyRecoveryCode, child: Text(_busy ? 'Verifying…' : 'Verify recovery code'))),
                      TextButton(onPressed: _busy ? null : () => setState(() { _recoveryMode = false; _recoveryCode.clear(); _error = null; }), child: const Text('Back to unlock')),
                    ] else if (_pinEntryEnabled) ...[
                    TextField(
                      controller: _pin,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 12,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      enabled: !_busy && !locked,
                      decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
                      onSubmitted: (_) {
                        if (_configured) {
                          _verifyPin();
                        } else {
                          _configurePin();
                        }
                      },
                    ),
                    if (!_configured) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _confirm,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 12,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        enabled: !_busy,
                        decoration: const InputDecoration(labelText: 'Confirm PIN', border: OutlineInputBorder()),
                        onSubmitted: (_) => _configurePin(),
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy || locked ? null : (_configured ? _verifyPin : _configurePin),
                        child: Text(
                          _busy
                              ? 'Please wait…'
                              : (locked
                                  ? 'Try again in ${remaining}s'
                                  : (_configured ? 'Unlock' : 'Save PIN and continue')),
                        ),
                      ),
                    ),
                    ],
                    if (_pinEntryEnabled == false && !_biometricEnabled) const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('PIN entry is disabled. Use Android device authentication to unlock.'),
                    ),
                    if (_configured && _pinEntryEnabled && !_recoveryMode) TextButton(onPressed: _busy ? null : () => setState(() { _recoveryMode = true; _recoveryCode.clear(); _error = null; }), child: const Text('Forgot PIN? Use recovery code')),
                    if (_deviceAuthAvailable && _biometricEnabled) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _tryDeviceAuthentication,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('Use device authentication'),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
).hasMatch(value)) {
        setState(() => _error = 'Enter the 32-character recovery code exactly as saved.');
        return;
      }
      final candidate = await _deriveHash(value, base64Decode(saltValue));
      if (!_constantTimeEquals(candidate, base64Decode(hashValue))) {
        setState(() => _error = 'Recovery code is incorrect. Your data has not been changed.');
        return;
      }
      _recoveryCode.clear();
      if (!mounted) return;
      setState(() { _recoveryMode = false; _configured = false; _error = null; });
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not verify the recovery code. $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _configurePin() async {
    final value = _pin.text;
    if (!RegExp(r'^[0-9]{6,12}$').hasMatch(value)) {
      setState(() => _error = 'Choose a PIN with 6 to 12 digits.');
      return;
    }
    if (value != _confirm.text) {
      setState(() => _error = 'The PINs do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final random = math.Random.secure();
      final salt = List<int>.generate(16, (_) => random.nextInt(256));
      final hash = await _deriveHash(value, salt);
      await widget.writeSecret(_saltKey, base64Encode(salt));
      await widget.writeSecret(_hashKey, base64Encode(hash));
      await widget.writeSecret(_attemptsKey, '0');
      await widget.deleteSecret(_lockUntilKey);
      if (!mounted) return;
      _pin.clear();
      _confirm.clear();
      await widget.onUnlocked();
    } catch (error) {
      try {
        await widget.deleteSecret(_saltKey);
        await widget.deleteSecret(_hashKey);
      } catch (_) {}
      if (mounted) setState(() => _error = 'Could not securely save the PIN. Try again. $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyPin() async {
    final now = DateTime.now();
    if (_lockUntil != null && now.isBefore(_lockUntil!)) {
      setState(() => _error = 'Too many attempts. Try again after ${_lockUntil!.toLocal()}.');
      return;
    }
    if (_lockUntil != null && !now.isBefore(_lockUntil!)) {
      _failedAttempts = 0;
      _lockUntil = null;
      await widget.writeSecret(_attemptsKey, '0');
      await widget.deleteSecret(_lockUntilKey);
    }
    final value = _pin.text;
    if (!RegExp(r'^[0-9]{6,12}$').hasMatch(value)) {
      setState(() => _error = 'Enter your 6 to 12 digit PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saltValue = await widget.readSecret(_saltKey);
      final hashValue = await widget.readSecret(_hashKey);
      if (saltValue == null || hashValue == null) throw StateError('PIN configuration is missing.');
      final candidate = await _deriveHash(value, base64Decode(saltValue));
      final expected = base64Decode(hashValue);
      if (_constantTimeEquals(candidate, expected)) {
        await widget.writeSecret(_attemptsKey, '0');
        await widget.deleteSecret(_lockUntilKey);
        _failedAttempts = 0;
        _lockUntil = null;
        _pin.clear();
        await widget.onUnlocked();
        return;
      }
      _failedAttempts += 1;
      await widget.writeSecret(_attemptsKey, _failedAttempts.toString());
      if (_failedAttempts >= 5) {
        _lockUntil = DateTime.now().add(const Duration(minutes: 5));
        await widget.writeSecret(_lockUntilKey, _lockUntil!.toIso8601String());
        _startLockoutTicker();
      }
      if (mounted) {
        setState(() {
          _error = _lockUntil == null
              ? 'Incorrect PIN. ${5 - _failedAttempts} attempts remain before a 5-minute lockout.'
              : 'Too many attempts. Access is locked for 5 minutes.';
        });
      }
      _pin.clear();
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not verify PIN securely. $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startLockoutTicker() {
    _lockoutTimer?.cancel();
    if (_lockUntil == null) return;
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lockUntil == null || !DateTime.now().isBefore(_lockUntil!)) {
        timer.cancel();
        setState(() {
          _lockUntil = null;
          _failedAttempts = 0;
          _error = null;
        });
        unawaited(widget.writeSecret(_attemptsKey, '0'));
        unawaited(widget.deleteSecret(_lockUntilKey));
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _tryDeviceAuthentication() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Unlock Aurelia PMS',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      if (!mounted) return;
      if (authenticated) {
        await widget.writeSecret(_attemptsKey, '0');
        await widget.deleteSecret(_lockUntilKey);
        _failedAttempts = 0;
        _lockUntil = null;
        await widget.onUnlocked();
      } else {
        setState(() => _error = 'Device authentication was cancelled or not accepted.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Device authentication is unavailable. Use your PIN. $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockUntil != null && DateTime.now().isBefore(_lockUntil!);
    final remaining = locked ? _lockUntil!.difference(DateTime.now()).inSeconds + 1 : 0;
    return Container(
      color: const Color(0xFFF3F7FA),
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    _loading ? 'Securing Aurelia PMS' : (_configured || !_pinEntryEnabled ? 'Unlock Aurelia PMS' : 'Create your PMS PIN'),
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your PMS data is encrypted on this device. Keep your PIN private and keep an encrypted backup somewhere safe.',
                    textAlign: TextAlign.center,
                  ),
                  if (_loading) const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(),
                  ),
                  if (!_loading && _error != null) Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                  ),
                  if (!_loading && !_configured && _pinEntryEnabled && _error == null) const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Choose 6–12 digits. This PIN is not recoverable by the developer; store it safely.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (!_loading && _error == null) ...[
                    const SizedBox(height: 16),
                    if (_pinEntryEnabled) ...[
                    TextField(
                      controller: _pin,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 12,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      enabled: !_busy && !locked,
                      decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
                      onSubmitted: (_) {
                        if (_configured) {
                          _verifyPin();
                        } else {
                          _configurePin();
                        }
                      },
                    ),
                    if (!_configured) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _confirm,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 12,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        enabled: !_busy,
                        decoration: const InputDecoration(labelText: 'Confirm PIN', border: OutlineInputBorder()),
                        onSubmitted: (_) => _configurePin(),
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy || locked ? null : (_configured ? _verifyPin : _configurePin),
                        child: Text(
                          _busy
                              ? 'Please wait…'
                              : (locked
                                  ? 'Try again in ${remaining}s'
                                  : (_configured ? 'Unlock' : 'Save PIN and continue')),
                        ),
                      ),
                    ),
                    ],
                    if (_pinEntryEnabled == false && !_biometricEnabled) const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('PIN entry is disabled. Use Android device authentication to unlock.'),
                    ),
                    if (_deviceAuthAvailable && _biometricEnabled) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _tryDeviceAuthentication,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('Use device authentication'),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
