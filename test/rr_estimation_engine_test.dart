import 'package:flutter_test/flutter_test.dart';
import 'package:gband_monitor/config/vitalvue_config.dart';
import 'package:gband_monitor/engine/rr_estimation_engine.dart';

void main() {
  group('RrEstimationEngine', () {
    test('Direct hardware breath data is validated under calm conditions', () {
      final engine = RrEstimationEngine(
        config: VitalVueProfileConfig.hospitalRpm(),
      );

      final now = DateTime(2026, 9, 28, 10, 0, 0);
      engine.addHardwareBreathRate(16, timestamp: now);

      final estimate = engine.pollValidatedRr(now: now, force: true);

      expect(estimate, isNotNull);
      expect(estimate!.isValidated, isTrue);
      expect(estimate.respiratoryRate, equals(16));
      expect(estimate.confidence, greaterThanOrEqualTo(0.85));
      expect(estimate.source, equals('hardware_sensor'));
    });

    test('Motion detection flags active physical movement', () {
      final engine = RrEstimationEngine(
        config: VitalVueProfileConfig.hospitalRpm(),
      );

      final now = DateTime(2026, 9, 28, 10, 0, 0);
      // Calm initially
      engine.addMotion(100, timestamp: now);
      expect(engine.isMotionArtifactPresent, isFalse);

      // Walking: 30 steps taken in 15 seconds
      engine.addMotion(130, timestamp: now.add(const Duration(seconds: 15)));
      expect(engine.isMotionArtifactPresent, isTrue);
    });

    test('Internal continuous derivation evaluates PPG beat variations', () {
      final engine = RrEstimationEngine(
        config: VitalVueProfileConfig.hospitalRpm(),
      );

      final start = DateTime(2026, 9, 28, 10, 0, 0);
      engine.addSpo2(98, timestamp: start);
      engine.addMotion(100, timestamp: start);

      // Feed simulated sinus arrhythmia beats over 60 seconds
      for (int i = 0; i < 60; i++) {
        final hr = (i % 8 < 4) ? 72 : 78; // Cyclical respiratory modulation
        engine.addHeartRate(hr, timestamp: start.add(Duration(seconds: i)));
      }

      final estimate = engine.pollValidatedRr(
        now: start.add(const Duration(seconds: 61)),
        force: true,
      );

      expect(estimate, isNotNull);
      expect(estimate!.respiratoryRate, inInclusiveRange(10, 30));
    });

    test('Hospital RPM profile enforces 5-min publication interval', () {
      final t0 = DateTime(2026, 9, 28, 12, 0, 0);
      final engine = RrEstimationEngine(
        config: VitalVueProfileConfig.hospitalRpm(), // 5-min publish interval
      );

      engine.addHardwareBreathRate(16, timestamp: t0);

      // First reading publishes
      final est1 = engine.pollValidatedRr(now: t0);
      expect(est1, isNotNull);
      expect(est1!.respiratoryRate, equals(16));

      // Reading 2 minutes later is throttled
      engine.addHardwareBreathRate(17, timestamp: t0.add(const Duration(minutes: 2)));
      final est2 = engine.pollValidatedRr(now: t0.add(const Duration(minutes: 2)));
      expect(est2, isNull);

      // Reading 5 minutes 1 second later is permitted
      engine.addHardwareBreathRate(17, timestamp: t0.add(const Duration(minutes: 5, seconds: 1)));
      final est3 = engine.pollValidatedRr(now: t0.add(const Duration(minutes: 5, seconds: 1)));
      expect(est3, isNotNull);
      expect(est3!.respiratoryRate, equals(17));
    });

    test('Consumer profile enforces 20-min publication interval', () {
      final t0 = DateTime(2026, 9, 28, 12, 0, 0);
      final engine = RrEstimationEngine(
        config: VitalVueProfileConfig.consumer(), // 20-min publish interval
      );

      engine.addHardwareBreathRate(15, timestamp: t0);

      final est1 = engine.pollValidatedRr(now: t0);
      expect(est1, isNotNull);

      // 10 minutes later is throttled in consumer mode
      engine.addHardwareBreathRate(16, timestamp: t0.add(const Duration(minutes: 10)));
      final est2 = engine.pollValidatedRr(now: t0.add(const Duration(minutes: 10)));
      expect(est2, isNull);

      // 21 minutes later is permitted
      engine.addHardwareBreathRate(16, timestamp: t0.add(const Duration(minutes: 21)));
      final est3 = engine.pollValidatedRr(now: t0.add(const Duration(minutes: 21)));
      expect(est3, isNotNull);
    });
  });
}
