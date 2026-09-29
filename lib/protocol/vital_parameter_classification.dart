/// Parameter Classification according to clinical architecture:
///
/// 1. Primary physiological deterioration parameters:
///    HR + RR + SpO2 + BP
///    These drive deterioration alerts, NEWS2 scoring, and urgent clinical interventions.
///
/// 2. Secondary / contextual parameters:
///    HRV + temperature + stress
///    Provide autonomic, metabolic, and situational context.
///
/// 3. Contextual / functional parameters:
///    steps + calories + distance + sleep
///    Assess mobility, energy expenditure, circadian stability, and functional recovery.
enum VitalCategory {
  primaryDeterioration,
  secondaryContextual,
  contextualFunctional;

  String get displayName => switch (this) {
        VitalCategory.primaryDeterioration => 'Primary Deterioration',
        VitalCategory.secondaryContextual => 'Secondary & Contextual',
        VitalCategory.contextualFunctional => 'Functional & Activity',
      };
}

/// Data freshness state based on measurement elapsed time vs recommended frequency.
enum VitalFreshness {
  fresh,       // Within recommended interval
  acceptable,  // Slightly past interval, still clinically valid
  stale,       // Past validity threshold, down-weighted in baseline scoring
  expired;     // Too old to be clinically reliable

  bool get isReliable => this == VitalFreshness.fresh || this == VitalFreshness.acceptable;
}

/// Data quality and origin flag for vital signals.
enum VitalQuality {
  validatedClinical, // Validated against clinical reference / quality-gated
  derivedPpg,        // Derived from PPG / HRV / motion algorithm
  sensorRaw,         // Direct sensor reading
  motionCorrupted,   // Sensor reading occurred during high activity / motion artifact
  unverified;        // Unverified fallback

  bool get isUsableForClinicalAlerts =>
      this == VitalQuality.validatedClinical || this == VitalQuality.sensorRaw;
}

/// Rich metadata container for a vital measurement.
class VitalReading<T> {
  final T value;
  final DateTime timestamp;
  final VitalCategory category;
  final VitalFreshness freshness;
  final VitalQuality quality;
  final double confidence;
  final String source;

  const VitalReading({
    required this.value,
    required this.timestamp,
    required this.category,
    required this.freshness,
    this.quality = VitalQuality.sensorRaw,
    this.confidence = 1.0,
    this.source = 'band_sensor',
  });

  bool get isValid => confidence > 0.4 && quality != VitalQuality.motionCorrupted;
}

/// Classification lookup helper.
class VitalClassifier {
  static VitalCategory categorize(String parameter) {
    return switch (parameter.toLowerCase()) {
      'hr' || 'heart_rate' || 'rr' || 'respiratory_rate' || 'spo2' || 'bp' || 'blood_pressure' =>
        VitalCategory.primaryDeterioration,
      'hrv' || 'temp' || 'temperature' || 'stress' =>
        VitalCategory.secondaryContextual,
      'steps' || 'calories' || 'distance' || 'sleep' =>
        VitalCategory.contextualFunctional,
      _ => VitalCategory.secondaryContextual,
    };
  }

  /// Calculates freshness based on last update and expected interval.
  static VitalFreshness calculateFreshness({
    required DateTime lastUpdated,
    required Duration expectedInterval,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final elapsed = current.difference(lastUpdated);

    if (elapsed <= expectedInterval) {
      return VitalFreshness.fresh;
    } else if (elapsed <= expectedInterval * 2) {
      return VitalFreshness.acceptable;
    } else if (elapsed <= expectedInterval * 4) {
      return VitalFreshness.stale;
    } else {
      return VitalFreshness.expired;
    }
  }
}
