/// Defines the operating mode of the VitalVue monitoring system.
///
/// - [hospitalRpm]: Designed for continuous clinical monitoring of admitted patients.
///   Features high-frequency continuous sensing, 1-min HR, 5-min SpO2/RR/HRV,
///   10-min Personal Baseline & NEWS2 recalculation, nurse-configurable BP.
///
/// - [consumer]: Designed for consumer health and wellness monitoring.
///   Optimized for battery conservation with 5-min HR, 15-30 min SpO2/RR (mainly overnight),
///   30-60 min Personal Baseline Score, and user/algorithm triggered BP.
enum AppProfileMode {
  hospitalRpm,
  consumer;

  String get displayName => switch (this) {
        AppProfileMode.hospitalRpm => 'Hospital RPM',
        AppProfileMode.consumer => 'Consumer Health',
      };

  bool get isHospital => this == AppProfileMode.hospitalRpm;
  bool get isConsumer => this == AppProfileMode.consumer;
}

enum BpMeasurementMode {
  nurseConfigurable,
  userOrAlgorithm,
}

enum BatteryPriority {
  high,
  medium,
  low,
  veryLow,
}

/// Frequency and operational parameters for a specific VitalVue profile.
class VitalVueProfileConfig {
  final AppProfileMode mode;

  // Measurement & publication intervals
  final Duration hrInterval;
  final Duration hrvInterval;
  final Duration rrInterval;
  final Duration spo2Interval;
  final Duration tempInterval;
  final Duration stressInterval;
  final Duration stepsInterval;
  final Duration caloriesInterval;
  final Duration distanceInterval;
  final Duration personalBaselineInterval;
  final BpMeasurementMode bpMode;
  final Duration ingestInterval;

  // BLE rotation duration settings
  final Duration hrDetectionDuration;
  final Duration spo2DetectionDuration;
  final Duration breathDetectionDuration;
  final Duration tempDetectionDuration;
  final Duration bpDetectionDuration;
  final Duration stressDetectionDuration;

  const VitalVueProfileConfig({
    required this.mode,
    required this.hrInterval,
    required this.hrvInterval,
    required this.rrInterval,
    required this.spo2Interval,
    required this.tempInterval,
    required this.stressInterval,
    required this.stepsInterval,
    required this.caloriesInterval,
    required this.distanceInterval,
    required this.personalBaselineInterval,
    required this.bpMode,
    required this.ingestInterval,
    required this.hrDetectionDuration,
    required this.spo2DetectionDuration,
    required this.breathDetectionDuration,
    required this.tempDetectionDuration,
    required this.bpDetectionDuration,
    required this.stressDetectionDuration,
  });

  bool get isHospital => mode.isHospital;
  bool get isConsumer => mode.isConsumer;
  bool get enableContinuousBpDetection => mode.isHospital;

  /// Creates profile configuration from [AppProfileMode].
  factory VitalVueProfileConfig.fromMode(AppProfileMode mode) {
    return switch (mode) {
      AppProfileMode.hospitalRpm => VitalVueProfileConfig.hospitalRpm(),
      AppProfileMode.consumer => VitalVueProfileConfig.consumer(),
    };
  }

  /// Factory for Hospital RPM configuration (the clinical default).
  factory VitalVueProfileConfig.hospitalRpm() {
    return const VitalVueProfileConfig(
      mode: AppProfileMode.hospitalRpm,
      hrInterval: Duration(minutes: 1), // Continuous sensing -> 1-min published value
      hrvInterval: Duration(minutes: 5),
      rrInterval: Duration(minutes: 5),
      spo2Interval: Duration(minutes: 5),
      tempInterval: Duration(minutes: 15),
      stressInterval: Duration(minutes: 12),
      stepsInterval: Duration(minutes: 2),
      caloriesInterval: Duration(minutes: 30),
      distanceInterval: Duration(minutes: 5),
      personalBaselineInterval: Duration(minutes: 10), // Recalculate baseline every 10 min
      bpMode: BpMeasurementMode.nurseConfigurable,
      ingestInterval: Duration(seconds: 60), // Clinical 1-min ingest
      hrDetectionDuration: Duration(seconds: 35),
      spo2DetectionDuration: Duration(seconds: 25),
      breathDetectionDuration: Duration(seconds: 25),
      tempDetectionDuration: Duration(seconds: 20),
      bpDetectionDuration: Duration(seconds: 55),
      stressDetectionDuration: Duration(seconds: 30),
    );
  }

  /// Factory for Consumer configuration (optimized for battery & lifestyle).
  factory VitalVueProfileConfig.consumer() {
    return const VitalVueProfileConfig(
      mode: AppProfileMode.consumer,
      hrInterval: Duration(minutes: 5),
      hrvInterval: Duration(minutes: 15), // 5-15 min / mainly overnight
      rrInterval: Duration(minutes: 20), // 15-30 min / overnight
      spo2Interval: Duration(minutes: 20), // 15-30 min / overnight
      tempInterval: Duration(minutes: 45), // 30-60 min
      stressInterval: Duration(minutes: 20), // 15-30 min
      stepsInterval: Duration(minutes: 5),
      caloriesInterval: Duration(minutes: 30),
      distanceInterval: Duration(minutes: 10),
      personalBaselineInterval: Duration(minutes: 45), // 30-60 min
      bpMode: BpMeasurementMode.userOrAlgorithm,
      ingestInterval: Duration(minutes: 5), // 5-min routine cloud transmission
      hrDetectionDuration: Duration(seconds: 25),
      spo2DetectionDuration: Duration(seconds: 20),
      breathDetectionDuration: Duration(seconds: 20),
      tempDetectionDuration: Duration(seconds: 15),
      bpDetectionDuration: Duration(seconds: 45),
      stressDetectionDuration: Duration(seconds: 25),
    );
  }

  /// Determines battery priority for a given vital parameter.
  BatteryPriority getBatteryPriority(String parameter) {
    return switch (parameter.toLowerCase()) {
      'hr' || 'heart_rate' => BatteryPriority.high,
      'rr' || 'respiratory_rate' || 'respiration' => BatteryPriority.high,
      'spo2' => BatteryPriority.high,
      'bp' || 'blood_pressure' => BatteryPriority.high,
      'personal_baseline' || 'baseline' => BatteryPriority.high,
      'hrv' => BatteryPriority.medium,
      'stress' => BatteryPriority.medium,
      'temp' || 'temperature' => BatteryPriority.low,
      'sleep' => BatteryPriority.low,
      'steps' || 'calories' || 'distance' => BatteryPriority.veryLow,
      _ => BatteryPriority.low,
    };
  }

  /// Global accessor for active app profile (Consumer Edition).
  static AppProfileMode get currentMode => AppProfileMode.consumer;

  /// Gets active profile configuration (Consumer Edition).
  static VitalVueProfileConfig get current => VitalVueProfileConfig.consumer();
}
