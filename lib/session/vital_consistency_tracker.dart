import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Diagnostic metrics for 24/7 vital delivery and cycle health.
class VitalConsistencyMetrics {
  const VitalConsistencyMetrics({
    this.totalCyclesCompleted = 0,
    this.totalPhasesAttempted = 0,
    this.totalPhasesWithData = 0,
    this.consistencyScore = 100.0,
    this.currentPhaseName = '',
    this.phaseStartedAt,
    this.lastBlePacketAt,
    this.lastHrAt,
    this.lastSpo2At,
    this.lastTempAt,
    this.lastBpAt,
    this.lastRrAt,
    this.lastHrvAt,
    this.lastStressAt,
    this.activeWarning,
  });

  final int totalCyclesCompleted;
  final int totalPhasesAttempted;
  final int totalPhasesWithData;
  final double consistencyScore;
  final String currentPhaseName;
  final DateTime? phaseStartedAt;
  final DateTime? lastBlePacketAt;

  final DateTime? lastHrAt;
  final DateTime? lastSpo2At;
  final DateTime? lastTempAt;
  final DateTime? lastBpAt;
  final DateTime? lastRrAt;
  final DateTime? lastHrvAt;
  final DateTime? lastStressAt;

  final String? activeWarning;

  VitalConsistencyMetrics copyWith({
    int? totalCyclesCompleted,
    int? totalPhasesAttempted,
    int? totalPhasesWithData,
    double? consistencyScore,
    String? currentPhaseName,
    DateTime? phaseStartedAt,
    DateTime? lastBlePacketAt,
    DateTime? lastHrAt,
    DateTime? lastSpo2At,
    DateTime? lastTempAt,
    DateTime? lastBpAt,
    DateTime? lastRrAt,
    DateTime? lastHrvAt,
    DateTime? lastStressAt,
    String? activeWarning,
    bool clearWarning = false,
  }) {
    return VitalConsistencyMetrics(
      totalCyclesCompleted: totalCyclesCompleted ?? this.totalCyclesCompleted,
      totalPhasesAttempted: totalPhasesAttempted ?? this.totalPhasesAttempted,
      totalPhasesWithData: totalPhasesWithData ?? this.totalPhasesWithData,
      consistencyScore: consistencyScore ?? this.consistencyScore,
      currentPhaseName: currentPhaseName ?? this.currentPhaseName,
      phaseStartedAt: phaseStartedAt ?? this.phaseStartedAt,
      lastBlePacketAt: lastBlePacketAt ?? this.lastBlePacketAt,
      lastHrAt: lastHrAt ?? this.lastHrAt,
      lastSpo2At: lastSpo2At ?? this.lastSpo2At,
      lastTempAt: lastTempAt ?? this.lastTempAt,
      lastBpAt: lastBpAt ?? this.lastBpAt,
      lastRrAt: lastRrAt ?? this.lastRrAt,
      lastHrvAt: lastHrvAt ?? this.lastHrvAt,
      lastStressAt: lastStressAt ?? this.lastStressAt,
      activeWarning: clearWarning ? null : (activeWarning ?? this.activeWarning),
    );
  }
}

/// Passive, non-intrusive 24/7 watchdog and consistency tracker for the GBand measurement cycle.
class VitalConsistencyTracker {
  VitalConsistencyTracker({
    required this.patientId,
    required this.deviceId,
    this.onMetricsChanged,
    this.onSchedulerStallDetected,
  });

  final int patientId;
  final String deviceId;
  final void Function(VitalConsistencyMetrics metrics)? onMetricsChanged;
  final Future<void> Function(String stalledPhase)? onSchedulerStallDetected;

  VitalConsistencyMetrics _metrics = const VitalConsistencyMetrics();
  VitalConsistencyMetrics get metrics => _metrics;

  // Throttling timers to prevent flooding Sentry with duplicate warnings
  final Map<String, DateTime> _lastSentryAlertTimestamps = {};

  // Maximum silence thresholds before warning on Sentry (while band is connected and worn)
  static const Duration _hrGapThreshold = Duration(minutes: 8);
  static const Duration _spo2GapThreshold = Duration(minutes: 8);
  static const Duration _tempGapThreshold = Duration(minutes: 12);
  static const Duration _bpGapThreshold = Duration(minutes: 18);
  static const Duration _rrGapThreshold = Duration(minutes: 8);
  static const Duration _silentBleThreshold = Duration(minutes: 4);

  // Cooldown between repeating identical Sentry alerts
  static const Duration _sentryAlertCooldown = Duration(minutes: 10);

  // ── Event Handlers ─────────────────────────────────────────────────────────

  /// Marks that a raw BLE packet or notification was received from the band.
  void recordBlePacket() {
    final now = DateTime.now();
    _metrics = _metrics.copyWith(lastBlePacketAt: now);
  }

  /// Called when a new scheduler phase starts.
  void recordPhaseStart(String phaseName, Duration expectedDuration) {
    final now = DateTime.now();
    final attempted = _metrics.totalPhasesAttempted + 1;
    _metrics = _metrics.copyWith(
      currentPhaseName: phaseName,
      phaseStartedAt: now,
      totalPhasesAttempted: attempted,
      lastBlePacketAt: now,
    );

    Sentry.addBreadcrumb(Breadcrumb(
      category: 'vitals.cycle',
      message: 'Phase started: $phaseName (Duration: ${expectedDuration.inSeconds}s, Total Attempted: $attempted)',
      level: SentryLevel.info,
    ));

    onMetricsChanged?.call(_metrics);
  }

  /// Called when a scheduler phase completes.
  void recordPhaseEnd(String phaseName, {required bool hadValidVital}) {
    final withData = _metrics.totalPhasesWithData + (hadValidVital ? 1 : 0);
    final attempted = _metrics.totalPhasesAttempted > 0 ? _metrics.totalPhasesAttempted : 1;
    final score = double.parse(((withData / attempted) * 100).toStringAsFixed(1));

    _metrics = _metrics.copyWith(
      totalPhasesWithData: withData,
      consistencyScore: score.clamp(0.0, 100.0),
      currentPhaseName: '',
      phaseStartedAt: null,
    );

    Sentry.addBreadcrumb(Breadcrumb(
      category: 'vitals.phase',
      message: 'Phase completed: $phaseName | Data received: $hadValidVital | Consistency: $score%',
      level: hadValidVital ? SentryLevel.info : SentryLevel.warning,
    ));

    onMetricsChanged?.call(_metrics);
  }

  /// Called when a full 5-phase rotation cycle completes.
  void recordCycleCompleted({
    int? hr,
    int? spo2,
    double? tempC,
    int? bpSys,
    int? bpDia,
  }) {
    final cycles = _metrics.totalCyclesCompleted + 1;
    _metrics = _metrics.copyWith(totalCyclesCompleted: cycles);

    debugPrint('[VitalConsistency] 🏁 Cycle #$cycles completed. Consistency: ${_metrics.consistencyScore}% (HR: $hr, SpO2: $spo2, Temp: $tempC, BP: $bpSys/$bpDia)');

    Sentry.addBreadcrumb(Breadcrumb(
      category: 'vitals.cycle',
      message: 'Cycle #$cycles completed. Consistency: ${_metrics.consistencyScore}% | HR: $hr, SpO2: $spo2, Temp: $tempC, BP: $bpSys/$bpDia',
      level: SentryLevel.info,
    ));

    onMetricsChanged?.call(_metrics);
  }

  /// Called whenever a valid vital reading is parsed.
  void recordVitalReading(String vitalType, dynamic value) {
    final now = DateTime.now();
    recordBlePacket();

    switch (vitalType) {
      case 'hr':
        _metrics = _metrics.copyWith(lastHrAt: now);
        break;
      case 'spo2':
        _metrics = _metrics.copyWith(lastSpo2At: now);
        break;
      case 'temp':
        _metrics = _metrics.copyWith(lastTempAt: now);
        break;
      case 'bp':
        _metrics = _metrics.copyWith(lastBpAt: now);
        break;
      case 'rr':
        _metrics = _metrics.copyWith(lastRrAt: now);
        break;
      case 'hrv':
        _metrics = _metrics.copyWith(lastHrvAt: now);
        break;
      case 'stress':
        _metrics = _metrics.copyWith(lastStressAt: now);
        break;
    }

    onMetricsChanged?.call(_metrics);
  }

  // ── Watchdog & Anomaly Detection ──────────────────────────────────────────

  /// Periodic watchdog check (should be called every 10–15s).
  /// Checks for scheduler freezes, vital delivery gaps, and silent connections.
  Future<void> evaluateConsistency({
    required bool isConnected,
    required bool isRemoved,
    required Duration currentPhaseDuration,
  }) async {
    if (!isConnected) {
      // Disconnected: reset active phase timestamps so we don't flag false stalls while offline
      if (_metrics.phaseStartedAt != null) {
        _metrics = _metrics.copyWith(phaseStartedAt: null, currentPhaseName: '');
      }
      return;
    }

    final now = DateTime.now();

    // 1. Detect Scheduler Phase Stall (Freeze)
    if (_metrics.phaseStartedAt != null && _metrics.currentPhaseName.isNotEmpty) {
      final elapsed = now.difference(_metrics.phaseStartedAt!);
      // Grace period: expected duration + 30 seconds
      final stallThreshold = currentPhaseDuration + const Duration(seconds: 30);

      if (elapsed > stallThreshold) {
        final stalledPhase = _metrics.currentPhaseName;
        debugPrint('[VitalConsistency] 🚨 CRITICAL: Scheduler STALL detected in phase "$stalledPhase"! Expected: ${currentPhaseDuration.inSeconds}s, Elapsed: ${elapsed.inSeconds}s');

        _captureThrottledAlert(
          key: 'stall_$stalledPhase',
          message: 'GBand Scheduler Stall: Phase "$stalledPhase" stuck for ${elapsed.inSeconds}s (expected ${currentPhaseDuration.inSeconds}s)',
          level: SentryLevel.error,
          tags: {
            'issue_type': 'scheduler_stall',
            'phase': stalledPhase,
            'device_id': deviceId,
            'patient_id': patientId.toString(),
          },
          extra: {
            'elapsed_seconds': elapsed.inSeconds,
            'expected_seconds': currentPhaseDuration.inSeconds,
            'total_cycles': _metrics.totalCyclesCompleted,
            'consistency_score': _metrics.consistencyScore,
          },
        );

        _metrics = _metrics.copyWith(
          activeWarning: 'Phase "$stalledPhase" stalled (${elapsed.inSeconds}s) - Recovering',
          phaseStartedAt: now, // Reset to prevent continuous triggering
        );
        onMetricsChanged?.call(_metrics);

        // Auto-recover stalled scheduler
        onSchedulerStallDetected?.call(stalledPhase);
        return;
      }
    }

    // Skip vital gap detection if user is not wearing the band
    if (isRemoved) {
      return;
    }

    // 2. Detect Silent BLE Connection (connected according to OS, but zero packets arriving)
    if (_metrics.lastBlePacketAt != null) {
      final elapsedSincePacket = now.difference(_metrics.lastBlePacketAt!);
      if (elapsedSincePacket > _silentBleThreshold) {
        _captureThrottledAlert(
          key: 'silent_ble',
          message: 'GBand Silent Connection: Connected but no BLE telemetry for ${elapsedSincePacket.inMinutes}m',
          level: SentryLevel.warning,
          tags: {
            'issue_type': 'silent_ble',
            'device_id': deviceId,
            'patient_id': patientId.toString(),
          },
          extra: {
            'silence_minutes': elapsedSincePacket.inMinutes,
            'total_cycles': _metrics.totalCyclesCompleted,
          },
        );
      }
    }

    // 3. Detect Vital Delivery Gaps
    _checkVitalGap('Heart Rate', _metrics.lastHrAt, _hrGapThreshold, 'hr');
    _checkVitalGap('SpO2', _metrics.lastSpo2At, _spo2GapThreshold, 'spo2');
    _checkVitalGap('Temperature', _metrics.lastTempAt, _tempGapThreshold, 'temp');
    _checkVitalGap('Blood Pressure', _metrics.lastBpAt, _bpGapThreshold, 'bp');
    _checkVitalGap('Respiration Rate', _metrics.lastRrAt, _rrGapThreshold, 'rr');
  }

  void _checkVitalGap(String vitalName, DateTime? lastSeen, Duration threshold, String key) {
    if (lastSeen == null) return; // Haven't received first reading yet (still in warmup)

    final elapsed = DateTime.now().difference(lastSeen);
    if (elapsed > threshold) {
      final gapMinutes = elapsed.inMinutes;
      debugPrint('[VitalConsistency] ⚠️ Vital Gap: $vitalName missing for ${gapMinutes}m (threshold: ${threshold.inMinutes}m)');

      _captureThrottledAlert(
        key: 'gap_$key',
        message: 'GBand Vital Delivery Gap: $vitalName missing for ${gapMinutes}m',
        level: SentryLevel.warning,
        tags: {
          'issue_type': 'vital_gap',
          'vital': key,
          'device_id': deviceId,
          'patient_id': patientId.toString(),
        },
        extra: {
          'vital_name': vitalName,
          'gap_minutes': gapMinutes,
          'threshold_minutes': threshold.inMinutes,
          'last_received_at': lastSeen.toIso8601String(),
          'total_cycles': _metrics.totalCyclesCompleted,
          'consistency_score': _metrics.consistencyScore,
        },
      );

      _metrics = _metrics.copyWith(activeWarning: '$vitalName delayed ($gapMinutes min)');
      onMetricsChanged?.call(_metrics);
    }
  }

  void _captureThrottledAlert({
    required String key,
    required String message,
    required SentryLevel level,
    required Map<String, String> tags,
    required Map<String, dynamic> extra,
  }) {
    final now = DateTime.now();
    final lastSent = _lastSentryAlertTimestamps[key];
    if (lastSent != null && now.difference(lastSent) < _sentryAlertCooldown) {
      return; // Throttled
    }

    _lastSentryAlertTimestamps[key] = now;

    Sentry.captureMessage(
      message,
      level: level,
      withScope: (scope) {
        tags.forEach((k, v) => scope.setTag(k, v));
        scope.setContexts('vital_consistency', extra);
      },
    );
  }
}
