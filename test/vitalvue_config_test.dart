import 'package:flutter_test/flutter_test.dart';
import 'package:gband_monitor/config/vitalvue_config.dart';

void main() {
  group('VitalVue Profile Configuration', () {
    test('Hospital RPM profile matches specification', () {
      final config = VitalVueProfileConfig.hospitalRpm();

      expect(config.mode, equals(AppProfileMode.hospitalRpm));
      expect(config.isHospital, isTrue);
      expect(config.isConsumer, isFalse);

      // Hospital frequencies
      expect(config.hrInterval, equals(const Duration(minutes: 1)));
      expect(config.hrvInterval, equals(const Duration(minutes: 5)));
      expect(config.rrInterval, equals(const Duration(minutes: 5)));
      expect(config.spo2Interval, equals(const Duration(minutes: 5)));
      expect(config.tempInterval, equals(const Duration(minutes: 15)));
      expect(config.stressInterval, equals(const Duration(minutes: 12)));
      expect(config.stepsInterval, equals(const Duration(minutes: 2)));
      expect(config.caloriesInterval, equals(const Duration(minutes: 30)));
      expect(config.distanceInterval, equals(const Duration(minutes: 5)));
      expect(config.personalBaselineInterval, equals(const Duration(minutes: 10)));
      expect(config.enableContinuousBpDetection, isTrue);

      // Battery priorities
      expect(config.getBatteryPriority('hr'), equals(BatteryPriority.high));
      expect(config.getBatteryPriority('rr'), equals(BatteryPriority.high));
      expect(config.getBatteryPriority('spo2'), equals(BatteryPriority.high));
      expect(config.getBatteryPriority('baseline'), equals(BatteryPriority.high));
      expect(config.getBatteryPriority('steps'), equals(BatteryPriority.veryLow));
    });

    test('Consumer profile matches specification', () {
      final config = VitalVueProfileConfig.consumer();

      expect(config.mode, equals(AppProfileMode.consumer));
      expect(config.isHospital, isFalse);
      expect(config.isConsumer, isTrue);

      // Consumer frequencies
      expect(config.hrInterval, equals(const Duration(minutes: 5)));
      expect(config.hrvInterval, equals(const Duration(minutes: 15)));
      expect(config.rrInterval, equals(const Duration(minutes: 20)));
      expect(config.spo2Interval, equals(const Duration(minutes: 20)));
      expect(config.tempInterval, equals(const Duration(minutes: 45)));
      expect(config.stressInterval, equals(const Duration(minutes: 20)));
      expect(config.stepsInterval, equals(const Duration(minutes: 5)));
      expect(config.caloriesInterval, equals(const Duration(minutes: 30)));
      expect(config.distanceInterval, equals(const Duration(minutes: 10)));
      expect(config.personalBaselineInterval, equals(const Duration(minutes: 45)));
      expect(config.enableContinuousBpDetection, isFalse); // Power saving
    });

    test('Active profile defaults to Consumer Edition on this branch', () {
      expect(VitalVueProfileConfig.currentMode, equals(AppProfileMode.consumer));
      expect(VitalVueProfileConfig.current.isConsumer, isTrue);
      expect(VitalVueProfileConfig.current.isHospital, isFalse);
    });
  });
}
