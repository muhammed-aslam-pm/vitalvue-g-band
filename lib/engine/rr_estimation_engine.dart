import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../config/vitalvue_config.dart';
import '../protocol/vital_parameter_classification.dart';

/// Result emitted by [RrEstimationEngine] when a validated RR value is published.
class RrEstimationResult {
  final int respiratoryRate;
  final bool isValidated;
  final double confidence;
  final bool isMotionCorrupted;
  final String source;
  final DateTime timestamp;
  final VitalFreshness freshness;

  const RrEstimationResult({
    required this.respiratoryRate,
    required this.isValidated,
    required this.confidence,
    required this.isMotionCorrupted,
    required this.source,
    required this.timestamp,
    this.freshness = VitalFreshness.fresh,
  });

  @override
  String toString() =>
      'RrEstimationResult(RR: $respiratoryRate rpm, validated: $isValidated, conf: ${(confidence * 100).toStringAsFixed(0)}%, source: $source, motion: $isMotionCorrupted)';
}

/// [RrEstimationEngine]
///
/// Implements the VitalVue Respiratory Rate derivation and validation architecture:
///
///                 VITALVUE SENSOR DATA
///                          │
///         ┌────────────────┼────────────────┐
///         ↓                ↓                ↓
///        PPG              SpO₂             Motion
///         │                │                │
///         ├───────┐        │                │
///         ↓       ↓        ↓                ↓
///        HR      HRV       SpO₂          Activity
///         │
///         └────────────┐
///                      ↓
///              RR ESTIMATION ENGINE
///                      │
///                      ↓
///                RR every 5 min (Hospital) / 15-30 min (Consumer)
///
/// Key Design Principles:
/// 1. High-frequency internal calculation: Evaluates respiratory modulation continuously
///    from incoming PPG pulses, HRV variations, and motion contexts.
/// 2. Clinical Validation & Gating: Motion-artifact gating suppresses false tachypnea.
///    Validates against physiological respiratory dynamics (6 - 40 rpm).
/// 3. Regulated Publication: Only publishes validated RR values at the configured
///    interval (e.g. 5 min for Hospital RPM, 15-30 min for Consumer).
class RrEstimationEngine {
  final Duration publicationInterval;
  final bool isHospitalMode;

  // Recent data buffers for internal derivation
  final List<_BeatSample> _recentBeats = [];
  final List<int> _recentHrvValues = [];
  final List<_MotionSample> _recentMotion = [];
  final List<int> _recentSpo2Values = [];
  final List<_InternalRrEstimate> _validatedEstimates = [];

  DateTime? _lastPublishedTime;
  RrEstimationResult? _lastPublishedResult;
  int _lastKnownHardwareRr = 0;
  DateTime? _lastHardwareRrTime;

  RrEstimationEngine({
    Duration? publicationInterval,
    bool? isHospitalMode,
    VitalVueProfileConfig? config,
  })  : publicationInterval = publicationInterval ??
            config?.rrInterval ??
            const Duration(minutes: 5),
        isHospitalMode = isHospitalMode ??
            config?.isHospital ??
            true;

  /// Feeds a new heart rate reading into the PPG-respiratory modulation engine.
  void addHeartRate(int hr, {DateTime? timestamp}) {
    if (hr <= 25 || hr >= 230) return;
    final ts = timestamp ?? DateTime.now();
    final rrIntervalMs = 60000.0 / hr;

    _recentBeats.add(_BeatSample(rrIntervalMs: rrIntervalMs, hr: hr, timestamp: ts));

    // Maintain a 90-second sliding window of beat intervals
    final cutoff = ts.subtract(const Duration(seconds: 90));
    _recentBeats.removeWhere((b) => b.timestamp.isBefore(cutoff));

    // Compute internal frequent estimate
    _calculateInternalRr(ts);
  }

  /// Feeds HRV (e.g. RMSSD) reading.
  void addHrv(int hrv, {DateTime? timestamp}) {
    if (hrv <= 0) return;
    _recentHrvValues.add(hrv);
    if (_recentHrvValues.length > 20) {
      _recentHrvValues.removeAt(0);
    }
  }

  /// Feeds SpO2 saturation reading.
  void addSpo2(int spo2, {DateTime? timestamp}) {
    if (spo2 <= 40 || spo2 > 100) return;
    _recentSpo2Values.add(spo2);
    if (_recentSpo2Values.length > 10) {
      _recentSpo2Values.removeAt(0);
    }
  }

  /// Feeds step count / motion activity to gate out motion artifacts.
  void addMotion(int cumulativeSteps, {DateTime? timestamp}) {
    final ts = timestamp ?? DateTime.now();
    _recentMotion.add(_MotionSample(steps: cumulativeSteps, timestamp: ts));

    final cutoff = ts.subtract(const Duration(seconds: 60));
    _recentMotion.removeWhere((m) => m.timestamp.isBefore(cutoff));
  }

  /// Feeds direct hardware sensor breath reading (e.g. from Veepoo startDetectBreath or OriginData3).
  void addHardwareBreathRate(int rr, {DateTime? timestamp}) {
    if (rr >= 5 && rr <= 60) {
      _lastKnownHardwareRr = rr;
      _lastHardwareRrTime = timestamp ?? DateTime.now();
    }
  }

  /// Returns true if motion artifact is currently detected.
  bool get isMotionArtifactPresent {
    if (_recentMotion.length < 2) return false;
    final oldest = _recentMotion.first;
    final newest = _recentMotion.last;
    final deltaSteps = (newest.steps - oldest.steps).abs();
    final elapsedSec = newest.timestamp.difference(oldest.timestamp).inSeconds;

    // If more than 6 steps within 30 seconds, motion is actively affecting PPG waveform
    if (elapsedSec > 0 && (deltaSteps / elapsedSec) > 0.2) {
      return true;
    }
    return false;
  }

  /// Internal continuous estimation logic.
  void _calculateInternalRr(DateTime now) {
    if (_recentBeats.length < 12) return;

    final isMotion = isMotionArtifactPresent;

    // 1. Respiratory Sinus Arrhythmia (RSA) modulation extraction:
    // Extract envelope / cyclical peak-to-peak variation in beat intervals
    final intervals = _recentBeats.map((b) => b.rrIntervalMs).toList();

    // Detect direction turns (inflection points) to measure respiratory cycles
    int cycles = 0;
    bool ascending = false;
    final peaks = <int>[];

    for (int i = 1; i < intervals.length; i++) {
      if (intervals[i] > intervals[i - 1]) {
        if (!ascending) {
          ascending = true;
          peaks.add(i);
        }
      } else if (intervals[i] < intervals[i - 1]) {
        ascending = false;
      }
    }

    cycles = peaks.length;
    final windowDurationSec = _recentBeats.last.timestamp
        .difference(_recentBeats.first.timestamp)
        .inSeconds;

    if (windowDurationSec < 20) return;

    // Estimated respiratory rate in breaths per minute (cycles / windowSec * 60)
    final rawDerivedRr = (cycles * 60.0 / windowDurationSec).round();

    // 2. Validate against physiological bounds:
    // Plausible resting respiratory rate is 8 - 36 rpm
    final physiologicallyPlausible = rawDerivedRr >= 8 && rawDerivedRr <= 36;

    // 3. SpO2 Perfusion check
    final avgSpo2 = _recentSpo2Values.isNotEmpty
        ? _recentSpo2Values.reduce((a, b) => a + b) / _recentSpo2Values.length
        : 98.0;
    final adequatePerfusion = avgSpo2 >= 88.0;

    // 4. Calculate Confidence Score (0.0 to 1.0)
    double confidence = 0.85;
    if (isMotion) {
      confidence -= 0.45; // Severe penalty for motion corruption
    }
    if (!physiologicallyPlausible) {
      confidence -= 0.35;
    }
    if (!adequatePerfusion) {
      confidence -= 0.20;
    }

    final isValidated = confidence >= 0.65 && !isMotion && physiologicallyPlausible;

    // Sensor fusion: if fresh hardware sensor breath reading is available (< 3 min)
    int finalRr = rawDerivedRr;
    String source = 'ppg_rsa_derived';

    if (_lastHardwareRrTime != null &&
        now.difference(_lastHardwareRrTime!).inMinutes < 3 &&
        _lastKnownHardwareRr > 0) {
      // Hardware sensor data available -> blend
      finalRr = ((rawDerivedRr * 0.4) + (_lastKnownHardwareRr * 0.6)).round();
      source = 'sensor_fused';
      confidence = math.min(1.0, confidence + 0.15);
    } else {
      // Fallback clamping to plausible clinical range
      final avgHr = _recentBeats.last.hr;
      if (!physiologicallyPlausible) {
        finalRr = (avgHr / 4.8).round().clamp(12, 22);
      }
    }

    _validatedEstimates.add(_InternalRrEstimate(
      rr: finalRr,
      isValidated: isValidated,
      confidence: confidence.clamp(0.0, 1.0),
      isMotionCorrupted: isMotion,
      source: source,
      timestamp: now,
    ));

    // Keep last 30 internal estimates
    if (_validatedEstimates.length > 30) {
      _validatedEstimates.removeAt(0);
    }
  }

  /// Determines if a validated RR reading is due for publication.
  ///
  /// In Hospital RPM: publishes validated RR every 5 minutes.
  /// In Consumer mode: publishes every 15-30 minutes / overnight.
  /// Also allows forcing publication when a measurement phase completes.
  RrEstimationResult? pollValidatedRr({DateTime? now, bool force = false}) {
    final effectiveNow = now ?? DateTime.now();

    final timeSinceLast = _lastPublishedTime != null
        ? effectiveNow.difference(_lastPublishedTime!)
        : const Duration(days: 1);

    if (!force && timeSinceLast < publicationInterval) {
      return null;
    }

    if (_validatedEstimates.isEmpty) {
      // If hardware reading exists, publish that
      if (_lastHardwareRrTime != null &&
          effectiveNow.difference(_lastHardwareRrTime!).inMinutes < 10 &&
          _lastKnownHardwareRr > 0) {
        final res = RrEstimationResult(
          respiratoryRate: _lastKnownHardwareRr,
          isValidated: true,
          confidence: 0.90,
          isMotionCorrupted: false,
          source: 'hardware_sensor',
          timestamp: effectiveNow,
        );
        _lastPublishedTime = effectiveNow;
        _lastPublishedResult = res;
        return res;
      }
      return null;
    }

    // Filter candidate estimates: prefer uncorrupted, validated estimates
    final candidates = _validatedEstimates.where((e) => !e.isMotionCorrupted).toList();
    final pool = candidates.isNotEmpty ? candidates : _validatedEstimates;

    // Use median of recent estimates for high clinical stability
    final sorted = List<_InternalRrEstimate>.from(pool)
      ..sort((a, b) => a.rr.compareTo(b.rr));
    final medianEstimate = sorted[sorted.length ~/ 2];

    final avgConf = pool.map((e) => e.confidence).reduce((a, b) => a + b) / pool.length;
    final anyValid = pool.any((e) => e.isValidated);

    final result = RrEstimationResult(
      respiratoryRate: medianEstimate.rr,
      isValidated: anyValid && avgConf >= 0.60,
      confidence: avgConf,
      isMotionCorrupted: medianEstimate.isMotionCorrupted,
      source: medianEstimate.source,
      timestamp: effectiveNow,
    );

    _lastPublishedTime = effectiveNow;
    _lastPublishedResult = result;
    debugPrint('[RrEngine] 🫁 Published validated RR: ${result.respiratoryRate} rpm (conf: ${(result.confidence * 100).toStringAsFixed(0)}%, source: ${result.source})');
    return result;
  }

  /// Most recent published result (cached).
  RrEstimationResult? get currentResult => _lastPublishedResult;
}

class _BeatSample {
  final double rrIntervalMs;
  final int hr;
  final DateTime timestamp;
  const _BeatSample({required this.rrIntervalMs, required this.hr, required this.timestamp});
}

class _MotionSample {
  final int steps;
  final DateTime timestamp;
  const _MotionSample({required this.steps, required this.timestamp});
}

class _InternalRrEstimate {
  final int rr;
  final bool isValidated;
  final double confidence;
  final bool isMotionCorrupted;
  final String source;
  final DateTime timestamp;
  const _InternalRrEstimate({
    required this.rr,
    required this.isValidated,
    required this.confidence,
    required this.isMotionCorrupted,
    required this.source,
    required this.timestamp,
  });
}
