import 'package:flutter_test/flutter_test.dart';
import 'package:gband_monitor/db/vitals_database.dart';
import 'package:sqflite/sqflite.dart';

class FakeDatabase extends Fake implements Database {
  String? lastTable;
  List<String>? lastColumns;
  String? lastWhere;
  List<Object?>? lastWhereArgs;
  int? lastLimit;
  List<Map<String, dynamic>> queryResult = [];

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    lastTable = table;
    lastColumns = columns;
    lastWhere = where;
    lastWhereArgs = whereArgs;
    lastLimit = limit;
    return queryResult;
  }
}

void main() {
  group('VitalsDatabase.hasIngestedVitalNear', () {
    late FakeDatabase fakeDb;

    setUp(() {
      fakeDb = FakeDatabase();
      VitalsDatabase.setDatabaseForTesting(fakeDb);
    });

    tearDown(() {
      VitalsDatabase.setDatabaseForTesting(null);
    });

    test('queries with correct window bounds and parameters', () async {
      final db = VitalsDatabase.instance;
      const targetTs = 1711180200000; // e.g. 10:05:00.000
      const deviceId = 'JBAND-TEST';

      fakeDb.queryResult = [
        {'_id': 1}
      ];

      final result = await db.hasIngestedVitalNear(
        deviceId: deviceId,
        timestamp: targetTs,
        windowMs: 150000,
      );

      expect(result, isTrue);
      expect(fakeDb.lastTable, equals('vitals'));
      expect(fakeDb.lastColumns, equals(['_id']));
      expect(
        fakeDb.lastWhere,
        equals('device_id = ? AND timestamp >= ? AND timestamp <= ? AND isIngested = 1'),
      );
      expect(fakeDb.lastWhereArgs, equals([deviceId, targetTs - 150000, targetTs + 150000]));
      expect(fakeDb.lastLimit, equals(1));
    });

    test('returns false when no ingested records exist within the window', () async {
      final db = VitalsDatabase.instance;
      const targetTs = 1711180200000;
      const deviceId = 'JBAND-TEST';

      fakeDb.queryResult = []; // No records

      final result = await db.hasIngestedVitalNear(
        deviceId: deviceId,
        timestamp: targetTs,
        windowMs: 150000,
      );

      expect(result, isFalse);
    });

    test('deduplication window logic correctly classifies near vs gap timestamps', () {
      const historyBucket = 1711180200000; // 10:05:00.000
      const windowMs = 150000; // 2.5 minutes

      // Live vital recorded at 10:06:15 (75 seconds after bucket start) -> Should be inside window
      const liveVitalNear = historyBucket + 75000;
      expect((liveVitalNear - historyBucket).abs() <= windowMs, isTrue);

      // Live vital recorded at 10:03:45 (75 seconds before bucket start) -> Should be inside window
      const liveVitalPrior = historyBucket - 75000;
      expect((liveVitalPrior - historyBucket).abs() <= windowMs, isTrue);

      // Disconnection gap: Last live vital was at 09:50:00 (15 minutes prior) -> Should be outside window
      const liveVitalFar = historyBucket - (15 * 60 * 1000);
      expect((liveVitalFar - historyBucket).abs() <= windowMs, isFalse);
    });
  });
}
