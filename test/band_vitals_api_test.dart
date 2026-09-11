import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gband_monitor/cloud/band_vitals_api.dart';

class MockHttpClientAdapter implements HttpClientAdapter {
  MockHttpClientAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('BandVitalsApi.buildVitalPayload', () {
    test('constructs vital payload matching API specification', () {
      final recordedAt = DateTime.utc(2026, 9, 3, 9, 20, 0);
      final payload = BandVitalsApi.buildVitalPayload(
        patientId: 101,
        deviceId: 'JBAND-9876',
        hr: 74,
        spo2: 98,
        respirationRate: 16,
        tempC: 36.5,
        tempSkin: 34.2,
        bpSys: 118,
        bpDia: 78,
        hrv: 52,
        stress: '15',
        movement: 0,
        steps: 1420,
        calories: 48.5,
        distanceKm: 0.95,
        battery: 85,
        phoneBattery: 72,
        isConnected: true,
        isRemoved: false,
        recordedAt: recordedAt,
      );

      expect(payload['patient_id'], 101);
      expect(payload['device_id'], 'JBAND-9876');
      expect(payload['heart_rate'], 74);
      expect(payload['spo2'], 98.0);
      expect(payload['temp'], 36.5);
      expect(payload['temp_skin'], 34.2);
      expect(payload['respiration_rate'], 16);
      expect(payload['bp_systolic'], 118);
      expect(payload['bp_diastolic'], 78);
      expect(payload['hrv_score'], 52);
      expect(payload['stress_level'], '15');
      expect(payload['movement'], 0);
      expect(payload['steps'], 1420);
      expect(payload['calories'], 48.5);
      expect(payload['distance_km'], 0.95);
      expect(payload['sleep_pattern'], 'unknown');
      expect(payload['battery_percent'], 85);
      expect(payload['phone_battery'], 72);
      expect(payload['is_connected'], true);
      expect(payload['is_removed'], false);
      expect(payload['timestamp'], recordedAt.millisecondsSinceEpoch);
      expect(payload['recorded_at'], '2026-09-03T09:20:00.000Z');
      expect(payload['created_at'], isA<String>());
    });
  });

  group('BandVitalsApi.bulkIngest', () {
    test('sends POST request to /api/v1/vitals/bulk-ingest with list payload', () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.httpClientAdapter = MockHttpClientAdapter((options) async {
        requests.add(options);
        return ResponseBody.fromString(
          jsonEncode({'message': 'Success'}),
          201,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final api = BandVitalsApi(
        baseUrl: 'https://vitalvue-api.genesysailabs.com',
        dio: dio,
      );

      final payloads = [
        BandVitalsApi.buildVitalPayload(
          patientId: 101,
          deviceId: 'JBAND-9876',
          hr: 74,
          spo2: 98,
          tempC: 36.5,
        ),
        BandVitalsApi.buildVitalPayload(
          patientId: 101,
          deviceId: 'JBAND-9876',
          hr: 78,
          spo2: 97,
          tempC: 36.6,
        ),
      ];

      final success = await api.bulkIngest(payloads);

      expect(success, isTrue);
      expect(requests.length, 1);
      expect(requests.first.path, 'https://vitalvue-api.genesysailabs.com/api/v1/vitals/bulk-ingest');
      expect(requests.first.method, 'POST');
      expect(requests.first.data, isA<List>());
      final data = requests.first.data as List;
      expect(data.length, 2);
      expect(data[0]['heart_rate'], 74);
      expect(data[1]['heart_rate'], 78);
    });

    test('splits payloads exceeding batchSize into multiple chunks', () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.httpClientAdapter = MockHttpClientAdapter((options) async {
        requests.add(options);
        return ResponseBody.fromString(
          jsonEncode({'message': 'Batch accepted'}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final api = BandVitalsApi(
        baseUrl: 'https://vitalvue-api.genesysailabs.com',
        dio: dio,
      );

      // Create 5 payloads, set batchSize = 2 -> 3 chunks (2, 2, 1)
      final payloads = List.generate(
        5,
        (i) => BandVitalsApi.buildVitalPayload(
          patientId: 101,
          deviceId: 'JBAND-9876',
          hr: 70 + i,
          spo2: 98,
          tempC: 36.5,
        ),
      );

      final success = await api.bulkIngest(payloads, batchSize: 2);

      expect(success, isTrue);
      expect(requests.length, 3);
      expect((requests[0].data as List).length, 2);
      expect((requests[1].data as List).length, 2);
      expect((requests[2].data as List).length, 1);
    });

    test('returns false when server returns error status code', () async {
      final dio = Dio();
      dio.httpClientAdapter = MockHttpClientAdapter((options) async {
        return ResponseBody.fromString(
          jsonEncode({'detail': 'Internal Server Error'}),
          500,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final api = BandVitalsApi(
        baseUrl: 'https://vitalvue-api.genesysailabs.com',
        dio: dio,
      );

      final payloads = [
        BandVitalsApi.buildVitalPayload(
          patientId: 101,
          deviceId: 'JBAND-9876',
          hr: 74,
          spo2: 98,
          tempC: 36.5,
        ),
      ];

      final success = await api.bulkIngest(payloads);
      expect(success, isFalse);
    });

    test('handles empty payloads gracefully', () async {
      final api = BandVitalsApi(
        baseUrl: 'https://vitalvue-api.genesysailabs.com',
      );

      final success = await api.bulkIngest([]);
      expect(success, isTrue);
    });
  });
}
