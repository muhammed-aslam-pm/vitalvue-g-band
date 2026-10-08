import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class VitalsDatabase {
  static final VitalsDatabase instance = VitalsDatabase._init();
  static Database? _database;

  VitalsDatabase._init();

  @visibleForTesting
  static void setDatabaseForTesting(Database? db) {
    _database = db;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('vitals_history.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 7,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        // Always recreate the table on any version bump to clear stale data.
        await db.execute('DROP TABLE IF EXISTS vitals');
        await _createDB(db, newVersion);
      },
      onOpen: (db) async {
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_vitals_dedup ON vitals(device_id, isIngested, timestamp)',
        );
      },
    );
  }

  Future _createDB(Database db, int version) async {
    const idType = 'INTEGER PRIMARY KEY AUTOINCREMENT';
    const integerType = 'INTEGER DEFAULT 0';
    const realType = 'REAL DEFAULT 0.0';
    const boolType = 'INTEGER DEFAULT 0';
    const textType = "TEXT DEFAULT '0'";

    await db.execute('''
CREATE TABLE vitals (
  _id $idType,
  timestamp $integerType,
  patient_id $integerType,
  device_id $textType,
  hr $integerType,
  spo2 $integerType,
  respirationRate $integerType,
  tempC $realType,
  tempSkin $realType,
  bpSys $integerType,
  bpDia $integerType,
  hrv $integerType,
  stress $textType,
  steps $integerType,
  calories $realType,
  distanceKm $realType,
  battery $integerType,
  isRemoved $boolType,
  isIngested $boolType,
  UNIQUE(timestamp, device_id)
  )
''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_vitals_dedup ON vitals(device_id, isIngested, timestamp)',
    );
  }

  Future<int> upsertVital(Map<String, dynamic> vital) async {
    final db = await instance.database;
    final mapped = Map<String, dynamic>.from(vital);
    if (mapped.containsKey('isRemoved')) {
      mapped['isRemoved'] = mapped['isRemoved'] == true ? 1 : 0;
    }
    if (mapped.containsKey('isIngested')) {
      mapped['isIngested'] = mapped['isIngested'] == true ? 1 : 0;
    }

    final timestamp = mapped['timestamp'];
    final deviceId = mapped['device_id'];
    
    if (timestamp != null && deviceId != null) {
      final existing = await db.query(
        'vitals',
        where: 'timestamp = ? AND device_id = ?',
        whereArgs: [timestamp, deviceId],
      );

      if (existing.isNotEmpty) {
        final existingMap = Map<String, dynamic>.from(existing.first);
        mapped.forEach((key, val) {
          if (val == 0 || val == 0.0 || val == null || val == '0' || val == '') {
            final oldVal = existingMap[key];
            if (oldVal != null && oldVal != 0 && oldVal != 0.0 && oldVal != '0' && oldVal != '') {
              mapped[key] = oldVal;
            }
          }
        });
        return await db.update(
          'vitals',
          mapped,
          where: 'timestamp = ? AND device_id = ?',
          whereArgs: [timestamp, deviceId],
        );
      }
    }
    return await db.insert('vitals', mapped);
  }

  /// Batches processing of historical records in a single database transaction
  /// to eliminate I/O disk lockups.
  Future<void> upsertHistoryRecords({
    required String deviceId,
    required int patientId,
    required List<Map<String, dynamic>> records,
  }) async {
    if (records.isEmpty) return;
    final db = await instance.database;
    await db.transaction((txn) async {
      for (final rec in records) {
        final hr = rec['hr'] as int? ?? 0;
        final sys = rec['bpSys'] as int? ?? 0;
        final dia = rec['bpDia'] as int? ?? 0;
        final tempC = (rec['tempC'] as num?)?.toDouble() ?? 0.0;
        final tempSkin = (rec['tempSkin'] as num?)?.toDouble() ?? 0.0;
        final steps = rec['steps'] as int? ?? 0;
        final calories = (rec['calories'] as num?)?.toDouble() ?? 0.0;
        final distanceKm = (rec['distanceKm'] as num?)?.toDouble() ?? 0.0;
        final stress = (rec['stress'] ?? '0').toString();
        final spo2 = rec['spo2'] as int? ?? 0;
        final rr = rec['respirationRate'] as int? ?? 0;
        final ts = rec['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

        if (hr == 0 && sys == 0 && tempC == 0.0 && steps == 0) continue;

        // Check deduplication within window
        final existingIngested = await txn.query(
          'vitals',
          columns: ['_id'],
          where: 'device_id = ? AND timestamp >= ? AND timestamp <= ? AND isIngested = 1',
          whereArgs: [deviceId, ts - 150000, ts + 150000],
          limit: 1,
        );
        final alreadyIngested = existingIngested.isNotEmpty;

        final mapped = <String, dynamic>{
          'timestamp': ts,
          'patient_id': patientId,
          'device_id': deviceId,
          'hr': hr,
          'spo2': spo2,
          'respirationRate': rr,
          'tempC': tempC,
          'tempSkin': tempSkin,
          'bpSys': sys,
          'bpDia': dia,
          'hrv': rec['hrv'] as int? ?? 0,
          'stress': stress,
          'steps': steps,
          'calories': calories,
          'distanceKm': distanceKm,
          'battery': -1,
          'isRemoved': 0,
          'isIngested': alreadyIngested ? 1 : 0,
        };

        final exactMatch = await txn.query(
          'vitals',
          where: 'timestamp = ? AND device_id = ?',
          whereArgs: [ts, deviceId],
          limit: 1,
        );

        if (exactMatch.isNotEmpty) {
          final existingMap = Map<String, dynamic>.from(exactMatch.first);
          mapped.forEach((key, val) {
            if (val == 0 || val == 0.0 || val == null || val == '0' || val == '') {
              final oldVal = existingMap[key];
              if (oldVal != null && oldVal != 0 && oldVal != 0.0 && oldVal != '0' && oldVal != '') {
                mapped[key] = oldVal;
              }
            }
          });
          await txn.update(
            'vitals',
            mapped,
            where: 'timestamp = ? AND device_id = ?',
            whereArgs: [ts, deviceId],
          );
        } else {
          await txn.insert('vitals', mapped);
        }
      }
    });
  }

  Future<int> insertVital(Map<String, dynamic> vital) async {
    final db = await instance.database;
    // ensure bools are integers
    final mapped = Map<String, dynamic>.from(vital);
    if (mapped.containsKey('isRemoved')) {
      mapped['isRemoved'] = mapped['isRemoved'] == true ? 1 : 0;
    }
    if (mapped.containsKey('isIngested')) {
      mapped['isIngested'] = mapped['isIngested'] == true ? 1 : 0;
    }
    return await db.insert(
      'vitals',
      mapped,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> getUningestedCount() async {
    final db = await instance.database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM vitals WHERE isIngested = 0');
    if (result.isNotEmpty) {
      return (result.first['count'] as int?) ?? 0;
    }
    return 0;
  }

  Future<List<Map<String, dynamic>>> getUningestedVitals({int? limit}) async {
    final db = await instance.database;
    return await db.query(
      'vitals',
      where: 'isIngested = ?',
      whereArgs: [0],
      orderBy: 'timestamp ASC',
      limit: limit,
    );
  }

  /// Checks whether an already-ingested vital record exists for [deviceId]
  /// within [windowMs] of [timestamp].
  ///
  /// Defaults to windowMs = 150,000 ms (±2.5 minutes), covering a full 5-minute bucket.
  Future<bool> hasIngestedVitalNear({
    required String deviceId,
    required int timestamp,
    int windowMs = 150000,
  }) async {
    try {
      final db = await instance.database;
      final start = timestamp - windowMs;
      final end = timestamp + windowMs;
      final results = await db.query(
        'vitals',
        columns: ['_id'],
        where: 'device_id = ? AND timestamp >= ? AND timestamp <= ? AND isIngested = 1',
        whereArgs: [deviceId, start, end],
        limit: 1,
      );
      return results.isNotEmpty;
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getVitalsForLast24Hours() async {
    final db = await instance.database;
    final oneDayAgo = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    return await db.query(
      'vitals',
      where: 'timestamp > ?',
      whereArgs: [oneDayAgo],
      orderBy: 'timestamp ASC',
    );
  }

  Future<void> markAsIngested(int id) async {
    final db = await instance.database;
    await db.update(
      'vitals',
      {'isIngested': 1},
      where: '_id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markMultipleAsIngested(List<int> ids) async {
    if (ids.isEmpty) return;
    try {
      final db = await instance.database;
      final batch = db.batch();
      for (final id in ids) {
        batch.update(
          'vitals',
          {'isIngested': 1},
          where: '_id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace, withScope: (scope) {
        scope.setContexts('Database', {'action': 'markMultipleAsIngested', 'ids_count': ids.length});
      });
      rethrow;
    }
  }

  Future<void> deleteOldVitals() async {
    final db = await instance.database;
    // Keep only the last 24 hours of data
    final oneDayAgo = DateTime.now()
        .subtract(const Duration(hours: 24))
        .millisecondsSinceEpoch;
    await db.delete(
      'vitals',
      where: 'timestamp < ?',
      whereArgs: [oneDayAgo],
    );
  }

  Future<void> close() async {
    final db = await instance.database;
    db.close();
  }
}
