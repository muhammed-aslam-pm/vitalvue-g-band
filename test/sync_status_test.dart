import 'package:flutter_test/flutter_test.dart';
import 'package:gband_monitor/bloc/band_monitor_state.dart';
import 'package:gband_monitor/protocol/veepoo_protocol.dart';
import 'package:gband_monitor/db/vitals_database.dart';
import 'package:sqflite/sqflite.dart';

class FakeDatabase extends Fake implements Database {
  String? lastRawQuery;
  List<Object?>? lastRawArguments;
  List<Map<String, Object?>> rawQueryResult = [];

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    lastRawQuery = sql;
    lastRawArguments = arguments;
    return rawQueryResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BandMonitorState Sync Status', () {
    test('BandIdleState has default isSyncing = false and syncRemaining = 0', () {
      const state = BandIdleState();
      expect(state.isSyncing, false);
      expect(state.syncRemaining, 0);
    });

    test('BandConnectedState preserves isSyncing and syncRemaining via copyWith', () {
      const state = BandConnectedState(
        BandState(),
        isSyncing: true,
        syncRemaining: 42,
      );
      expect(state.isSyncing, true);
      expect(state.syncRemaining, 42);

      final updated = state.copyWith(
        vitals: const BandState(hr: 75),
      );
      expect(updated.isSyncing, true);
      expect(updated.syncRemaining, 42);
      expect(updated.vitals.hr, 75);

      final finished = updated.copyWith(
        isSyncing: false,
        syncRemaining: 0,
      );
      expect(finished.isSyncing, false);
      expect(finished.syncRemaining, 0);
    });

    test('BandConnectingState and BandDisconnectedState carry sync properties', () {
      const connecting = BandConnectingState(
        'GBand Pro',
        isSyncing: true,
        syncRemaining: 15,
      );
      expect(connecting.deviceName, 'GBand Pro');
      expect(connecting.isSyncing, true);
      expect(connecting.syncRemaining, 15);

      const disconnected = BandDisconnectedState(
        reason: 'User disconnected',
        isSyncing: false,
        syncRemaining: 0,
      );
      expect(disconnected.reason, 'User disconnected');
      expect(disconnected.isSyncing, false);
      expect(disconnected.syncRemaining, 0);
    });
  });

  group('VitalsDatabase.getUningestedCount', () {
    late FakeDatabase fakeDb;

    setUp(() {
      fakeDb = FakeDatabase();
      VitalsDatabase.setDatabaseForTesting(fakeDb);
    });

    tearDown(() {
      VitalsDatabase.setDatabaseForTesting(null);
    });

    test('returns count from rawQuery when uningested records exist', () async {
      fakeDb.rawQueryResult = [
        {'count': 2}
      ];

      final count = await VitalsDatabase.instance.getUningestedCount();
      expect(count, 2);
      expect(fakeDb.lastRawQuery, contains('SELECT COUNT(*) as count FROM vitals WHERE isIngested = 0'));
    });

    test('returns 0 when rawQuery returns empty list or count is 0', () async {
      fakeDb.rawQueryResult = [];
      final count = await VitalsDatabase.instance.getUningestedCount();
      expect(count, 0);

      fakeDb.rawQueryResult = [
        {'count': 0}
      ];
      final countZero = await VitalsDatabase.instance.getUningestedCount();
      expect(countZero, 0);
    });
  });
}
