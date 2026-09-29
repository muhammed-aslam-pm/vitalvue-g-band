import 'package:flutter_test/flutter_test.dart';
import 'package:gband_monitor/config/vitalvue_config.dart';
import 'package:gband_monitor/engine/personal_baseline_engine.dart';
import 'package:gband_monitor/protocol/veepoo_protocol.dart';

void main() {
  group('PersonalBaselineEngine & NEWS2 Calculation', () {
    final engine = PersonalBaselineEngine(
      config: VitalVueProfileConfig.hospitalRpm(),
    );

    test('Normal physiological parameters result in NEWS2 = 0 and high baseline score', () {
      final now = DateTime.now();
      final state = const BandState().copyWith(
        hr: 72,
        respiratoryRate: 16,
        spo2: 98,
        systolic: 120,
        diastolic: 80,
        tempC: 36.8,
        hrv: 45,
        stress: 25,
      );

      final timestamps = {
        'hr': now,
        'respirationRate': now,
        'spo2': now,
        'bpSys': now,
        'tempC': now,
        'hrv': now,
        'stress': now,
      };

      final result = engine.compute(state, timestamps: timestamps, now: now);

      expect(result.news2Score, equals(0));
      expect(result.baselineScore, greaterThanOrEqualTo(90));
      expect(result.trendStatus, equals('stable'));
      expect(result.clinicalSummary, contains('Stable physiological vitals'));
    });

    test('Critical respiratory rate and hypoxia trigger high NEWS2 and critical trend', () {
      final now = DateTime.now();
      // Patient deteriorating: RR = 28 (score 3), SpO2 = 88% (score 3), HR = 135 (score 3), BP = 85 (score 3)
      final state = const BandState().copyWith(
        hr: 135,
        respiratoryRate: 28,
        spo2: 88,
        systolic: 85,
        diastolic: 55,
        tempC: 39.5,
      );

      final timestamps = {
        'hr': now,
        'respirationRate': now,
        'spo2': now,
        'bpSys': now,
        'tempC': now,
      };

      final result = engine.compute(state, timestamps: timestamps, now: now);

      // NEWS2: RR(3) + SpO2(3) + HR(3) + BP(3) + Temp(2) = 14
      expect(result.news2Score, equals(14));
      expect(result.trendStatus, equals('critical'));
      expect(result.baselineScore, lessThan(50));
      expect(result.clinicalSummary, contains('Critical deterioration detected'));
    });

    test('NEWS2 specific parameter scoring rules', () {
      // Respiratory rate score rules
      expect(PersonalBaselineEngine.scoreRr(6), equals(3));
      expect(PersonalBaselineEngine.scoreRr(10), equals(1));
      expect(PersonalBaselineEngine.scoreRr(16), equals(0));
      expect(PersonalBaselineEngine.scoreRr(22), equals(2));
      expect(PersonalBaselineEngine.scoreRr(26), equals(3));

      // SpO2 score rules
      expect(PersonalBaselineEngine.scoreSpo2(89), equals(3));
      expect(PersonalBaselineEngine.scoreSpo2(92), equals(2));
      expect(PersonalBaselineEngine.scoreSpo2(94), equals(1));
      expect(PersonalBaselineEngine.scoreSpo2(98), equals(0));

      // Systolic BP score rules
      expect(PersonalBaselineEngine.scoreSystolic(85), equals(3));
      expect(PersonalBaselineEngine.scoreSystolic(95), equals(2));
      expect(PersonalBaselineEngine.scoreSystolic(105), equals(1));
      expect(PersonalBaselineEngine.scoreSystolic(125), equals(0));
      expect(PersonalBaselineEngine.scoreSystolic(230), equals(3));

      // Heart Rate score rules
      expect(PersonalBaselineEngine.scoreHeartRate(38), equals(3));
      expect(PersonalBaselineEngine.scoreHeartRate(48), equals(1));
      expect(PersonalBaselineEngine.scoreHeartRate(72), equals(0));
      expect(PersonalBaselineEngine.scoreHeartRate(98), equals(1));
      expect(PersonalBaselineEngine.scoreHeartRate(120), equals(2));
      expect(PersonalBaselineEngine.scoreHeartRate(140), equals(3));

      // Temperature score rules
      expect(PersonalBaselineEngine.scoreTemperature(34.8), equals(3));
      expect(PersonalBaselineEngine.scoreTemperature(35.5), equals(1));
      expect(PersonalBaselineEngine.scoreTemperature(37.0), equals(0));
      expect(PersonalBaselineEngine.scoreTemperature(38.5), equals(1));
      expect(PersonalBaselineEngine.scoreTemperature(39.3), equals(2));
    });

    test('Recalculation intervals respect profile configuration', () {
      final now = DateTime(2026, 9, 28, 14, 0, 0);

      // Hospital profile: 10-minute interval
      final hospitalEngine = PersonalBaselineEngine(
        config: VitalVueProfileConfig.hospitalRpm(),
      );
      expect(hospitalEngine.shouldRecalculate(now: now), isTrue);
      hospitalEngine.markRecalculated(now: now);
      expect(hospitalEngine.shouldRecalculate(now: now.add(const Duration(minutes: 5))), isFalse);
      expect(hospitalEngine.shouldRecalculate(now: now.add(const Duration(minutes: 10, seconds: 1))), isTrue);

      // Consumer profile: 45-minute interval
      final consumerEngine = PersonalBaselineEngine(
        config: VitalVueProfileConfig.consumer(),
      );
      expect(consumerEngine.shouldRecalculate(now: now), isTrue);
      consumerEngine.markRecalculated(now: now);
      expect(consumerEngine.shouldRecalculate(now: now.add(const Duration(minutes: 20))), isFalse);
      expect(consumerEngine.shouldRecalculate(now: now.add(const Duration(minutes: 46))), isTrue);
    });
  });
}
