import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Encrypted SQLCipher store for the full browser PMS state payload.
///
/// The payload is stored as a versioned snapshot rather than guessed relational
/// tables: the legacy JS model contains more entities than the migration bridge
/// can safely infer. Relational projections should be introduced with explicit
/// schema mappings and reconciliation tests.
class AureliaMigrationStore {
  AureliaMigrationStore._();
  static final AureliaMigrationStore instance = AureliaMigrationStore._();

  static const _vault = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true, resetOnError: true),
  );
  static const _keyName = 'aurelia_sqlcipher_key_v1';
  static const _databaseName = 'aurelia_pms_encrypted.db';
  Database? _database;

  Future<Database> _open() async {
    if (_database != null && _database!.isOpen) return _database!;
    var key = await _vault.read(key: _keyName);
    if (key == null || key.length < 40) {
      final random = Random.secure();
      key = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
      await _vault.write(key: _keyName, value: key);
    }
    final dir = await getApplicationSupportDirectory();
    _database = await openDatabase(
      p.join(dir.path, _databaseName),
      password: key,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE app_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            schema_version INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            payload_digest TEXT NOT NULL,
            record_counts_json TEXT NOT NULL,
            migrated_at TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE TABLE migration_log (id INTEGER PRIMARY KEY AUTOINCREMENT, source_key TEXT NOT NULL, payload_digest TEXT NOT NULL, record_counts_json TEXT NOT NULL, verified_at TEXT NOT NULL)');
      },
    );
    return _database!;
  }

  Map<String, dynamic> _counts(Map<String, dynamic> data) {
    final counts = <String, dynamic>{};
    for (final entry in data.entries) {
      if (entry.value is List) counts[entry.key] = (entry.value as List).length;
    }
    return counts;
  }

  /// Stores the complete payload transactionally. The caller must not delete
  /// WebView localStorage unless this returns verified=true and a subsequent
  /// independent read-back matches the digest and counts.
  Future<Map<String, dynamic>> ingest(String rawPayload) async {
    if (rawPayload.length > 20 * 1024 * 1024) {
      throw const FormatException('Migration payload exceeds 20 MiB limit');
    }
    final decoded = jsonDecode(rawPayload);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Migration payload must be a JSON object');
    }
    final rawData = decoded['data'];
    if (rawData is! Map) {
      throw const FormatException('Migration payload has no data object');
    }
    final data = Map<String, dynamic>.from(rawData);
    final payloadJson = jsonEncode(decoded);
    final countsJson = jsonEncode(_counts(data));
    // SHA-256 is used for deterministic corruption/read-back detection.
    final digest = sha256.convert(utf8.encode(payloadJson)).toString();
    final db = await _open();

    await db.transaction((txn) async {
      await txn.insert('app_state', {
        'id': 1,
        'schema_version': decoded['migrationProtocol'] is int ? decoded['migrationProtocol'] : 1,
        'payload_json': payloadJson,
        'payload_digest': digest,
        'record_counts_json': countsJson,
        'migrated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('migration_log', {
        'source_key': (decoded['storageKeys'] is List && (decoded['storageKeys'] as List).isNotEmpty)
            ? (decoded['storageKeys'] as List).first.toString()
            : 'unknown',
        'payload_digest': digest,
        'record_counts_json': countsJson,
        'verified_at': DateTime.now().toUtc().toIso8601String(),
      });
    });

    final integrity = await db.rawQuery('PRAGMA integrity_check');
    final row = await db.query('app_state', where: 'id = ?', whereArgs: [1], limit: 1);
    if (integrity.isEmpty || integrity.first.values.first != 'ok' || row.isEmpty) {
      throw StateError('SQLite integrity/read-back verification failed');
    }
    final stored = row.first['payload_json'] as String;
    final storedData = (jsonDecode(stored) as Map<String, dynamic>)['data'] as Map<String, dynamic>;
    final storedCounts = _counts(storedData);
    final verified = sha256.convert(utf8.encode(stored)).toString() == digest &&
        jsonEncode(storedCounts) == countsJson &&
        storedData.keys.toSet().containsAll(data.keys.toSet());

    if (!verified) throw StateError('Migration snapshot did not reconcile');
    return {
      'verified': true,
      'schemaVersion': 1,
      'digest': digest,
      'counts': storedCounts,
      'integrityCheck': integrity.first.values.first,
      'sourceStorageRetained': true,
    };
  }

  Future<Map<String, dynamic>?> readVerifiedSnapshot() async {
    final db = await _open();
    final rows = await db.query('app_state', where: 'id = ?', whereArgs: [1], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final payload = row['payload_json'] as String;
    if (sha256.convert(utf8.encode(payload)).toString() != row['payload_digest']) {
      throw StateError('Stored PMS snapshot digest mismatch');
    }
    return jsonDecode(payload) as Map<String, dynamic>;
  }

}
