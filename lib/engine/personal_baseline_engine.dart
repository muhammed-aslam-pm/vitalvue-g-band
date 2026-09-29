import 'dart:math' as math;
import '../config/vitalvue_config.dart';
import '../protocol/veepoo_protocol.dart';
import '../protocol/vital_parameter_classification.dart';

/// Clinical risk category according to NHS NEWS2 standard.
enum News2RiskLevel {
  low,      // Score 0-4
  medium,   // Score 5-6 or red score 3 in single parameter
  high;     // Score >= 7

  String get displayName => switch (this) {
        News2RiskLevel.low => 'Low Risk',
        News2RiskLevel.medium => 'Medium Risk',
        News2RiskLevel.high => 'High / Critical Risk',
      };
}

/// Trend classification indicating trajectory of physiological stability.
enum PhysiologicalTrend {
  improving,
  stable,
  deteriorating,
  critical;

  String get displayName => switch (this) {
        PhysiologicalTrend.improving => 'Improving',
        PhysiologicalTrend.stable => 'Stable',
        PhysiologicalTrend.deteriorating => 'Deteriorating',
        PhysiologicalTrend.critical => 'Critical Deterioration',
      };
}

/// Complete output bundle from the Personal Baseline Engine.
class PersonalBaselineReport {
  final int personalBaselineScore; // 0 - 100
  final int news2Score;            // 0 - 20
  final News2RiskLevel news2Risk;
  final PhysiologicalTrend trend;
  final String clinicalSummary;
  final Map<String, VitalFreshness> freshnessMap;
  final Map<String, double> parameterScores;
  final DateTime evaluatedAt;

  const PersonalBaselineReport({
    required this.personalBaselineScore,
    required this.news2Score,
    required this.news2Risk,
    required this.trend,
    required this.clinicalSummary,
    required this.freshnessMap,
    required this.parameterScores,
    required this.evaluatedAt,
  });

  int get baselineScore => personalBaselineScore;
  String get trendStatus => trend.name;
}

/// Baseline reference model holding personalized baseline norms.
class PatientPersonalBaseline {
  final double restingHr;
  final double restingRr;
  final double baselineSpo2;
  final double baselineSystolic;
  final double baselineHrv;
  final double baselineTempC;

  const PatientPersonalBaseline({
    this.restingHr = 72.0,
    this.restingRr = 16.0,
    this.baselineSpo2 = 98.0,
    this.baselineSystolic = 120.0,
    this.baselineHrv = 45.0,
    this.baselineTempC = 36.6,
  });
}

/// [PersonalBaselineEngine]
///
/// Recalculates personal baseline score, NEWS2, and deterioration trends
/// at configured intervals (every 10 min for Hospital RPM, every 30-60 min for Consumer).
///
/// Handles disparate parameter arrival frequencies gracefully:
/// Uses the most recent valid measurement for each parameter and applies
/// freshness / quality flags.
class PersonalBaselineEngine {
  final VitalVueProfileConfig profileConfig;
  PatientPersonalBaseline baseline;

  final List<PersonalBaselineReport> _recentReports = [];
  DateTime? _lastEvaluationTime;

  PersonalBaselineEngine({
    VitalVueProfileConfig? profileConfig,
    VitalVueProfileConfig? config,
    this.baseline = const PatientPersonalBaseline(),
  }) : profileConfig = profileConfig ?? config ?? VitalVueProfileConfig.hospitalRpm();

  static int scoreRr(int rr) {
    if (rr <= 0) return 0;
    if (rr <= 8) return 3;
    if (rr >= 9 && rr <= 11) return 1;
    if (rr >= 12 && rr <= 20) return 0;
    if (rr >= 21 && rr <= 24) return 2;
    return 3;
  }

  static int scoreSpo2(int spo2) {
    if (spo2 <= 0) return 0;
    if (spo2 <= 91) return 3;
    if (spo2 >= 92 && spo2 <= 93) return 2;
    if (spo2 >= 94 && spo2 <= 95) return 1;
    return 0;
  }

  static int scoreSystolic(int systolicBp) {
    if (systolicBp <= 0) return 0;
    if (systolicBp <= 90) return 3;
    if (systolicBp >= 91 && systolicBp <= 100) return 2;
    if (systolicBp >= 101 && systolicBp <= 110) return 1;
    if (systolicBp >= 111 && systolicBp <= 219) return 0;
    return 3;
  }

  static int scoreHeartRate(int hr) {
    if (hr <= 0) return 0;
    if (hr <= 40) return 3;
    if (hr >= 41 && hr <= 50) return 1;
    if (hr >= 51 && hr <= 90) return 0;
    if (hr >= 91 && hr <= 110) return 1;
    if (hr >= 111 && hr <= 130) return 2;
    return 3;
  }

  static int scoreTemperature(double tempC) {
    if (tempC <= 0) return 0;
    if (tempC <= 35.0) return 3;
    if (tempC > 35.0 && tempC <= 36.0) return 1;
    if (tempC > 36.0 && tempC <= 38.0) return 0;
    if (tempC > 38.0 && tempC <= 39.0) return 1;
    return 2;
  }

  /// Evaluates NEWS2 score based on physiological deterioration parameters:
  /// HR + RR + SpO2 + Systolic BP + Temp.
  int calculateNews2({
    required int hr,
    required int rr,
    required int spo2,
    required int systolicBp,
    required double tempC,
  }) {
    return scoreRr(rr) +
        scoreSpo2(spo2) +
        scoreSystolic(systolicBp) +
        scoreHeartRate(hr) +
        scoreTemperature(tempC);
  }

  /// Calculates individual parameter stability score (0.0 to 100.0)
  /// measuring deviation from personal baseline.
  double _scoreParameterDeviation({
    required double actual,
    required double baselineValue,
    required double tolerance,
  }) {
    if (actual <= 0) return 80.0; // Default when unmeasured
    final diff = (actual - baselineValue).abs();
    if (diff <= tolerance) return 100.0;
    final penalty = ((diff - tolerance) / tolerance) * 25.0;
    return (100.0 - penalty).clamp(0.0, 100.0);
  }

  /// Evaluates data freshness weight (1.0 for fresh, down to 0.0 for expired).
  double _freshnessWeight(VitalFreshness freshness) {
    return switch (freshness) {
      VitalFreshness.fresh => 1.0,
      VitalFreshness.acceptable => 0.8,
      VitalFreshness.stale => 0.4,
      VitalFreshness.expired => 0.0,
    };
  }

  /// Main evaluation method.
  ///
  /// Recalculates Personal Baseline Score, NEWS2, Freshness flags, and Trends.
  PersonalBaselineReport evaluate({
    required int hr,
    required DateTime hrTimestamp,
    required int rr,
    required DateTime rrTimestamp,
    required int spo2,
    required DateTime spo2Timestamp,
    required int systolicBp,
    required int diastolicBp,
    required DateTime bpTimestamp,
    required double tempC,
    required DateTime tempTimestamp,
    required int hrv,
    required DateTime hrvTimestamp,
    required int stress,
    required DateTime stressTimestamp,
    required int steps,
    required int totalSleepMinutes,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();

    // 1. Compute Freshness Map
    final freshnessMap = <String, VitalFreshness>{
      'hr': VitalClassifier.calculateFreshness(
        lastUpdated: hrTimestamp,
        expectedInterval: profileConfig.hrInterval,
        now: current,
      ),
      'rr': VitalClassifier.calculateFreshness(
        lastUpdated: rrTimestamp,
        expectedInterval: profileConfig.rrInterval,
        now: current,
      ),
      'spo2': VitalClassifier.calculateFreshness(
        lastUpdated: spo2Timestamp,
        expectedInterval: profileConfig.spo2Interval,
        now: current,
      ),
      'bp': VitalClassifier.calculateFreshness(
        lastUpdated: bpTimestamp,
        expectedInterval: const Duration(hours: 4),
        now: current,
      ),
      'temp': VitalClassifier.calculateFreshness(
        lastUpdated: tempTimestamp,
        expectedInterval: profileConfig.tempInterval,
        now: current,
      ),
      'hrv': VitalClassifier.calculateFreshness(
        lastUpdated: hrvTimestamp,
        expectedInterval: profileConfig.hrvInterval,
        now: current,
      ),
      'stress': VitalClassifier.calculateFreshness(
        lastUpdated: stressTimestamp,
        expectedInterval: profileConfig.stressInterval,
        now: current,
      ),
    };

    // 2. Compute NEWS2 Score (Hospital deterioration metric)
    final news2 = calculateNews2(
      hr: hr,
      rr: rr,
      spo2: spo2,
      systolicBp: systolicBp,
      tempC: tempC,
    );

    final news2Risk = switch (news2) {
      >= 7 => News2RiskLevel.high,
      >= 5 => News2RiskLevel.medium,
      _ => News2RiskLevel.low,
    };

    // 3. Compute Personal Baseline Parameter Scores
    final paramScores = <String, double>{
      'hr': _scoreParameterDeviation(
        actual: hr.toDouble(),
        baselineValue: baseline.restingHr,
        tolerance: 15.0,
      ),
      'rr': _scoreParameterDeviation(
        actual: rr.toDouble(),
        baselineValue: baseline.restingRr,
        tolerance: 4.0,
      ),
      'spo2': spo2 >= 96 ? 100.0 : (spo2 >= 92 ? 80.0 : 40.0),
      'bp': systolicBp > 0
          ? _scoreParameterDeviation(
              actual: systolicBp.toDouble(),
              baselineValue: baseline.baselineSystolic,
              tolerance: 20.0,
            )
          : 90.0,
      'temp': tempC > 0
          ? _scoreParameterDeviation(
              actual: tempC,
              baselineValue: baseline.baselineTempC,
              tolerance: 0.8,
            )
          : 90.0,
      'hrv': hrv > 0
          ? _scoreParameterDeviation(
              actual: hrv.toDouble(),
              baselineValue: baseline.baselineHrv,
              tolerance: 20.0,
            )
          : 85.0,
      'stress': stress > 0 ? (100.0 - (stress * 0.7)).clamp(30.0, 100.0) : 85.0,
    };

    // 4. Weighted Personal Baseline Score Calculation
    // Primary Deterioration Parameters: 60%
    // Secondary / Contextual: 30%
    // Contextual / Functional: 10%
    double primarySum = 0.0;
    double primaryWeights = 0.0;
    for (final p in ['hr', 'rr', 'spo2', 'bp']) {
      final w = _freshnessWeight(freshnessMap[p] ?? VitalFreshness.fresh);
      primarySum += (paramScores[p] ?? 85.0) * w;
      primaryWeights += w;
    }
    final primaryScore = primaryWeights > 0 ? primarySum / primaryWeights : 85.0;

    double secondarySum = 0.0;
    double secondaryWeights = 0.0;
    for (final p in ['hrv', 'temp', 'stress']) {
      final w = _freshnessWeight(freshnessMap[p] ?? VitalFreshness.fresh);
      secondarySum += (paramScores[p] ?? 85.0) * w;
      secondaryWeights += w;
    }
    final secondaryScore = secondaryWeights > 0 ? secondarySum / secondaryWeights : 85.0;

    // Functional bonus (sleep & activity)
    double functionalScore = 85.0;
    if (totalSleepMinutes > 360) functionalScore += 10.0;
    if (steps > 2000) functionalScore += 5.0;
    functionalScore = functionalScore.clamp(0.0, 100.0);

    int finalBaselineScore = (
      (primaryScore * 0.60) +
      (secondaryScore * 0.30) +
      (functionalScore * 0.10)
    ).round().clamp(0, 100);

    // Clinical deterioration gating:
    // When high/critical deterioration is detected via NEWS2, clamp baseline score
    // so secondary/functional defaults do not mask acute deterioration.
    if (news2 >= 7) {
      finalBaselineScore = math.min(finalBaselineScore, 40);
    } else if (news2 >= 5) {
      finalBaselineScore = math.min(finalBaselineScore, 60);
    }

    // 5. Determine Trend Trajectory
    PhysiologicalTrend trend = PhysiologicalTrend.stable;
    if (_recentReports.isNotEmpty) {
      final previous = _recentReports.last;
      final scoreDelta = finalBaselineScore - previous.personalBaselineScore;
      final newsDelta = news2 - previous.news2Score;

      if (news2 >= 7 || finalBaselineScore < 50) {
        trend = PhysiologicalTrend.critical;
      } else if (newsDelta >= 2 || scoreDelta <= -12) {
        trend = PhysiologicalTrend.deteriorating;
      } else if (scoreDelta >= 6 && newsDelta <= 0) {
        trend = PhysiologicalTrend.improving;
      } else {
        trend = PhysiologicalTrend.stable;
      }
    } else {
      if (news2 >= 7 || finalBaselineScore < 50) {
        trend = PhysiologicalTrend.critical;
      } else if (news2 >= 5 || finalBaselineScore < 70) {
        trend = PhysiologicalTrend.deteriorating;
      }
    }

    // 6. Clinical Summary String
    final summary = _generateSummary(
      news2: news2,
      risk: news2Risk,
      trend: trend,
      score: finalBaselineScore,
      hr: hr,
      rr: rr,
      spo2: spo2,
    );

    final report = PersonalBaselineReport(
      personalBaselineScore: finalBaselineScore,
      news2Score: news2,
      news2Risk: news2Risk,
      trend: trend,
      clinicalSummary: summary,
      freshnessMap: freshnessMap,
      parameterScores: paramScores,
      evaluatedAt: current,
    );

    _recentReports.add(report);
    if (_recentReports.length > 20) {
      _recentReports.removeAt(0);
    }
    _lastEvaluationTime = current;

    return report;
  }

  String _generateSummary({
    required int news2,
    required News2RiskLevel risk,
    required PhysiologicalTrend trend,
    required int score,
    required int hr,
    required int rr,
    required int spo2,
  }) {
    if (trend == PhysiologicalTrend.critical || risk == News2RiskLevel.high) {
      return 'Critical deterioration detected (NEWS2: $news2). Elevated risk in deterioration parameters.';
    }
    if (trend == PhysiologicalTrend.deteriorating || risk == News2RiskLevel.medium) {
      return 'Deterioration warning: Physiological baseline deviation (Score: $score/100, NEWS2: $news2).';
    }
    if (trend == PhysiologicalTrend.improving) {
      return 'Vitals recovering toward personal baseline (Score: $score/100).';
    }
    return 'Stable physiological vitals within personal baseline tolerances (Score: $score/100).';
  }

  /// Checks if evaluation is due based on configured interval.
  bool isEvaluationDue({DateTime? now}) {
    if (_lastEvaluationTime == null) return true;
    final current = now ?? DateTime.now();
    return current.difference(_lastEvaluationTime!) >= profileConfig.personalBaselineInterval;
  }

  /// Convenience alias for [isEvaluationDue].
  bool shouldRecalculate({DateTime? now}) => isEvaluationDue(now: now);

  /// Marks evaluation time as now.
  void markRecalculated({DateTime? now}) {
    _lastEvaluationTime = now ?? DateTime.now();
  }

  /// Convenience alias for [evaluate] using a [BandState] snapshot.
  PersonalBaselineReport compute(
    BandState state, {
    Map<String, DateTime>? timestamps,
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    return evaluate(
      hr: state.hr,
      hrTimestamp: timestamps?['hr'] ?? effectiveNow,
      rr: state.respiratoryRate,
      rrTimestamp: timestamps?['respirationRate'] ?? timestamps?['rr'] ?? effectiveNow,
      spo2: state.spo2,
      spo2Timestamp: timestamps?['spo2'] ?? effectiveNow,
      systolicBp: state.systolic ?? 0,
      diastolicBp: state.diastolic ?? 0,
      bpTimestamp: timestamps?['bpSys'] ?? timestamps?['bp'] ?? effectiveNow,
      tempC: state.tempC,
      tempTimestamp: timestamps?['tempC'] ?? timestamps?['temp'] ?? effectiveNow,
      hrv: state.hrv ?? 0,
      hrvTimestamp: timestamps?['hrv'] ?? effectiveNow,
      stress: state.stress ?? 0,
      stressTimestamp: timestamps?['stress'] ?? effectiveNow,
      steps: state.steps,
      totalSleepMinutes: state.totalSleepMinutes,
      now: effectiveNow,
    );
  }

  PersonalBaselineReport? get latestReport =>
      _recentReports.isNotEmpty ? _recentReports.last : null;
}
