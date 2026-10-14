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
    final dir = await getApplicationSupportDirectory();
    final databaseFile = File(p.join(dir.path, _databaseName));
    if (key == null || key.length < 40) {
      // Never silently replace a lost key when an encrypted database exists:
      // doing so makes the existing PMS data permanently unreadable.
      if (await databaseFile.exists()) {
        throw StateError(
          'SQLCipher key is missing or invalid while the encrypted database exists. '
          'Keep the database intact and use the documented recovery process.',
        );
      }
      final random = Random.secure();
      key = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
      await _vault.write(key: _keyName, value: key);
      final writtenKey = await _vault.read(key: _keyName);
      if (writtenKey != key) {
        throw StateError('Could not verify secure database-key persistence.');
      }
    }
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

  Map<String, int> _counts(Map<String, dynamic> data) {
    final counts = <String, int>{};
    for (final entry in data.entries) {
      if (entry.value is List) counts[entry.key] = (entry.value as List).length;
    }
    return counts;
  }

  Map<String, dynamic> _decodePayload(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['app'] != 'Aurelia PMS' ||
        decoded['migrationProtocol'] != 1 ||
        decoded['data'] is! Map) {
      throw const FormatException('Unsupported or malformed migration payload');
    }
    final data = Map<String, dynamic>.from(decoded['data'] as Map);
    final expectedCounts = _counts(data);
    final suppliedCounts = decoded['counts'];
    if (suppliedCounts != null) {
      if (suppliedCounts is! Map ||
          suppliedCounts.length != expectedCounts.length ||
          expectedCounts.entries.any((entry) =>
              suppliedCounts[entry.key] != entry.value)) {
        throw const FormatException('Migration record counts do not match payload');
      }
    }
    return decoded;
  }

  /// Stores the complete payload transactionally. The caller must not delete
  /// WebView localStorage unless this returns verified=true and a subsequent
  /// independent read-back matches the digest and counts.
  Future<Map<String, dynamic>> ingest(String rawPayload) async {
    if (rawPayload.length > 20 * 1024 * 1024) {
      throw const FormatException('Migration payload exceeds 20 MiB limit');
    }
    final decoded = _decodePayload(rawPayload);
    final data = Map<String, dynamic>.from(decoded['data'] as Map);
    final payloadJson = jsonEncode(decoded);
    final countsJson = jsonEncode(_counts(data));
    // SHA-256 is used for deterministic corruption/read-back detection.
    final digest = sha256.convert(utf8.encode(payloadJson)).toString();
    final db = await _open();

    final previousRows = await db.query(
      'app_state',
      columns: ['payload_digest'],
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    final alreadyCurrent = previousRows.isNotEmpty &&
        previousRows.first['payload_digest'] == digest;

    await db.transaction((txn) async {
      await txn.insert('app_state', {
        'id': 1,
        'schema_version': decoded['migrationProtocol'] is int ? decoded['migrationProtocol'] : 1,
        'payload_json': payloadJson,
        'payload_digest': digest,
        'record_counts_json': countsJson,
        'migrated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // Repeated page loads of the same snapshot must not create an
      // unbounded log of duplicate successful migrations.
      final logged = await txn.query(
        'migration_log',
        columns: ['id'],
        where: 'payload_digest = ?',
        whereArgs: [digest],
        limit: 1,
      );
      if (logged.isEmpty) {
        await txn.insert('migration_log', {
          'source_key': (decoded['storageKeys'] is List &&
                  (decoded['storageKeys'] as List).isNotEmpty)
              ? (decoded['storageKeys'] as List).first.toString()
              : 'unknown',
          'payload_digest': digest,
          'record_counts_json': countsJson,
          'verified_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
    });

    final integrity = await db.rawQuery('PRAGMA integrity_check');
    final row = await db.query('app_state', where: 'id = ?', whereArgs: [1], limit: 1);
    if (integrity.isEmpty || integrity.first.values.first != 'ok' || row.isEmpty) {
      throw StateError('SQLite integrity/read-back verification failed');
    }
    final stored = row.first['payload_json'] as String;
    final storedDecoded = _decodePayload(stored);
    final storedData = Map<String, dynamic>.from(storedDecoded['data'] as Map);
    final storedCounts = _counts(storedData);
    final storedCountsJson = jsonEncode(storedCounts);
    final verified = row.first['schema_version'] == decoded['migrationProtocol'] &&
        row.first['payload_digest'] == digest &&
        sha256.convert(utf8.encode(stored)).toString() == digest &&
        storedCountsJson == countsJson &&
        storedCountsJson == row.first['record_counts_json'] &&
        storedData.keys.toSet().containsAll(data.keys.toSet());

    if (!verified) throw StateError('Migration snapshot did not reconcile');
    return {
      'verified': true,
      'alreadyCurrent': alreadyCurrent,
      'schemaVersion': decoded['migrationProtocol'],
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
