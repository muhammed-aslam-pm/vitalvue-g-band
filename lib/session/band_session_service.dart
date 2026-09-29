import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:veepoo_sdk/veepoo_sdk.dart';
import '../config/vitalvue_config.dart';
import '../engine/rr_estimation_engine.dart';
import '../engine/personal_baseline_engine.dart';
import '../protocol/veepoo_protocol.dart';
import 'vital_consistency_tracker.dart';

class VitalsScheduleDurations {
  const VitalsScheduleDurations({
    this.spo2Duration = const Duration(seconds: 20),
    this.breathDuration = const Duration(seconds: 25),
    this.tempDuration = const Duration(seconds: 20),
    this.bpDuration = const Duration(seconds: 55),
    this.stressDuration = const Duration(seconds: 35),
    this.hrHrvDuration = const Duration(seconds: 35),
    this.ingestInterval = const Duration(seconds: 60),
  });

  factory VitalsScheduleDurations.fromProfile(VitalVueProfileConfig config) {
    return VitalsScheduleDurations(
      spo2Duration: config.spo2DetectionDuration,
      breathDuration: config.breathDetectionDuration,
      tempDuration: config.tempDetectionDuration,
      bpDuration: config.bpDetectionDuration,
      stressDuration: config.stressDetectionDuration,
      hrHrvDuration: config.hrDetectionDuration,
      ingestInterval: config.ingestInterval,
    );
  }

  final Duration spo2Duration;
  final Duration breathDuration;
  final Duration tempDuration;
  final Duration bpDuration;
  final Duration stressDuration;
  final Duration hrHrvDuration;
  final Duration ingestInterval;
}

class BandSessionService {
  BandSessionService({
    required this.patientId,
    required this.deviceId,
    required PersonalInfo personalInfo,
    required this.onIngest,
    this.onHistoryRecords,
    this.onHistoryComplete,
    VitalVueProfileConfig? profileConfig,
    VitalsScheduleDurations? scheduleDurations,
  })  : profileConfig = profileConfig ?? VitalVueProfileConfig.current,
        scheduleDurations = scheduleDurations ??
            VitalsScheduleDurations.fromProfile(profileConfig ?? VitalVueProfileConfig.current),
        _personalInfo = personalInfo {
    _rrEngine = RrEstimationEngine(
      publicationInterval: (profileConfig ?? VitalVueProfileConfig.current).rrInterval,
      isHospitalMode: (profileConfig ?? VitalVueProfileConfig.current).mode.isHospital,
    );
    _baselineEngine = PersonalBaselineEngine(
      profileConfig: profileConfig ?? VitalVueProfileConfig.current,
    );

    _consistencyTracker = VitalConsistencyTracker(
      patientId: patientId,
      deviceId: deviceId,
      onMetricsChanged: (metrics) {
        _emit(_state.copyWith(
          consistencyScore: metrics.consistencyScore,
          cycleCount: metrics.totalCyclesCompleted,
          activePhase: metrics.currentPhaseName,
          vitalGapWarning: metrics.activeWarning,
        ));
      },
      onSchedulerStallDetected: (stalledPhase) async {
        debugPrint('[BandSession] ⚡ Auto-recovering from stalled phase: $stalledPhase');
        _schedulerTimer?.cancel();
        _schedulerTimer = null;
        try {
          final phases = _getPhases();
          if (phases.isNotEmpty) {
            final current = phases[_cyclePhase % phases.length];
            await current.stop();
          }
        } catch (_) {}
        _cyclePhase++;
        _runNextPhase();
      },
    );
  }

  final int patientId;
  final String deviceId;
  final PersonalInfo _personalInfo;
  final Future<void> Function(BandState state) onIngest;
  final Future<void> Function(List<Map<String, dynamic>> records)? onHistoryRecords;
  final Future<void> Function()? onHistoryComplete;
  final VitalVueProfileConfig profileConfig;
  final VitalsScheduleDurations scheduleDurations;

  late final RrEstimationEngine _rrEngine;
  late final PersonalBaselineEngine _baselineEngine;
  Timer? _baselineTimer;

  // Measurement timestamps for freshness evaluation
  DateTime _lastHrTime = DateTime.now();
  DateTime _lastRrTime = DateTime.now();
  DateTime _lastSpo2Time = DateTime.now();
  DateTime _lastBpTime = DateTime.now();
  DateTime _lastTempTime = DateTime.now();
  DateTime _lastHrvTime = DateTime.now();
  DateTime _lastStressTime = DateTime.now();

  final VeepooSdk _sdk = VeepooSdk();

  late final VitalConsistencyTracker _consistencyTracker;
  VitalConsistencyTracker get consistencyTracker => _consistencyTracker;

  BandState _state = const BandState();
  final _controller = StreamController<BandState>.broadcast();
  Stream<BandState> get stateStream => _controller.stream;
  BandState get currentState => _state;

  StreamSubscription? _eventSub;
  Timer? _hrIngestTimer;   // fires every ingestInterval → ingest current vitals
  Timer? _otherTimer;      // fires every 5 min → restart BP / SpO2 / Temp
  Timer? _watchdogTimer;   // fires every 2s → evaluates off-wrist status & vital consistency
  Timer? _wearErrorConfirmTimer; // debounces wear errors to prevent false positives on momentary strap adjustments
  DateTime _lastValidPulseTime = DateTime.now();
  bool _currentPhaseHadValidVital = false;
  int _consecutiveFailedPhases = 0;
  Completer<void>? _historyReadCompleter;

  final List<double> _recentRrIntervals = [];

  void _confirmBandRemoved([String reason = 'hardware']) {
    _wearErrorConfirmTimer?.cancel();
    _wearErrorConfirmTimer = null;
    if (!_state.isRemoved) {
      debugPrint('[BandSession] ⌚ Band removal confirmed ($reason). Setting isRemoved=true');
      _emit(_state.copyWith(
        isRemoved: true,
        hr: 0,
        spo2: 0,
      ));
      // Trigger immediate ingest so cloud and database receive is_removed=true without delay
      onIngest(_state);
    }
  }

  void _onValidVitalsReceived([String? info]) {
    _wearErrorConfirmTimer?.cancel();
    _wearErrorConfirmTimer = null;
    _currentPhaseHadValidVital = true;
    _consecutiveFailedPhases = 0;
    _lastValidPulseTime = DateTime.now();
    if (_state.isRemoved) {
      debugPrint('[BandSession] ⌚ Band re-worn: valid vitals received ($info). Setting isRemoved=false');
      _emit(_state.copyWith(isRemoved: false));
      onIngest(_state);
    }
  }

  void _processHrvFromHeartRate(int hr) {
    if (hr <= 20 || hr >= 220) return;
    final rrMs = 60000.0 / hr;
    _recentRrIntervals.add(rrMs);
    if (_recentRrIntervals.length > 30) {
      _recentRrIntervals.removeAt(0);
    }
    if (_recentRrIntervals.length >= 5) {
      double sumSqDiff = 0.0;
      for (int i = 0; i < _recentRrIntervals.length - 1; i++) {
        final diff = _recentRrIntervals[i + 1] - _recentRrIntervals[i];
        sumSqDiff += diff * diff;
      }
      final rmssd = math.sqrt(sumSqDiff / (_recentRrIntervals.length - 1)).round();
      if (rmssd > 10 && rmssd < 200) {
        _lastHrvTime = DateTime.now();
        _rrEngine.addHrv(rmssd);
        _emit(_state.copyWith(hrv: rmssd));
      }
    }
  }

  void _recalculatePersonalBaseline() {
    if (_state.connectionStatus != BleConnectionStatus.connected) return;
    final report = _baselineEngine.evaluate(
      hr: _state.hr,
      hrTimestamp: _lastHrTime,
      rr: _state.respiratoryRate,
      rrTimestamp: _lastRrTime,
      spo2: _state.spo2,
      spo2Timestamp: _lastSpo2Time,
      systolicBp: _state.systolic ?? 0,
      diastolicBp: _state.diastolic ?? 0,
      bpTimestamp: _lastBpTime,
      tempC: _state.tempC,
      tempTimestamp: _lastTempTime,
      hrv: _state.hrv ?? 0,
      hrvTimestamp: _lastHrvTime,
      stress: _state.stress ?? 0,
      stressTimestamp: _lastStressTime,
      steps: _state.steps,
      totalSleepMinutes: _state.totalSleepMinutes,
    );

    _emit(_state.copyWith(
      news2Score: report.news2Score,
      personalBaselineScore: report.personalBaselineScore,
      trendStatus: report.trend.name,
      parameterFreshness: report.freshnessMap.map((k, v) => MapEntry(k, v.name)),
      clinicalSummary: report.clinicalSummary,
    ));
    debugPrint('[BandSession] 📊 Baseline Score: ${report.personalBaselineScore}/100, NEWS2: ${report.news2Score}, Trend: ${report.trend.displayName}');
  }

  void _tickWatchdog() {
    if (_state.connectionStatus != BleConnectionStatus.connected) return;
    if (_state.isEcgMeasuring) return;

    final now = DateTime.now();
    final secondsSinceValidPulse = now.difference(_lastValidPulseTime).inSeconds;

    // Full rotation takes ~165s. If no valid vitals (HR, SpO2, BP, Stress) received for > 270s (4.5 minutes / ~1.6 rotations), flag as removed
    if (secondsSinceValidPulse > 270 && !_state.isRemoved) {
      debugPrint('[BandSession] ⚠️ WATCHDOG EXPIRED: No valid vitals for ${secondsSinceValidPulse}s. Flagging band as removed.');
      _confirmBandRemoved('watchdog_expired (${secondsSinceValidPulse}s no vitals)');
    }

    // 24/7 Vital Consistency & Anomaly Watchdog evaluation
    final phases = _getPhases();
    final currentDuration = phases.isNotEmpty
        ? phases[_cyclePhase % phases.length].duration
        : const Duration(seconds: 35);

    _consistencyTracker.evaluateConsistency(
      isConnected: _state.connectionStatus == BleConnectionStatus.connected,
      isRemoved: _state.isRemoved,
      currentPhaseDuration: currentDuration,
    );
  }

  Future<bool> connect(String macAddress) async {
    _emit(_state.copyWith(connectionStatus: BleConnectionStatus.connecting));

    // Listen to events from the Native SDK
    _eventSub ??= _sdk.events.listen(_onEvent);

    bool ok = await _sdk.connect(macAddress);
    if (!ok) {
      debugPrint('[BandSession] First connection attempt failed. Retrying in 1.2s...');
      await Future.delayed(const Duration(milliseconds: 1200));
      ok = await _sdk.connect(macAddress);
    }

    if (!ok) {
      _emit(_state.copyWith(
        connectionStatus: BleConnectionStatus.disconnected,
        errorMessage: 'Connection failed',
      ));
      return false;
    }
    return true;
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (type == null) return;
    _consistencyTracker.recordBlePacket();
    
    switch(type) {
      case 'connectionState':
        final state = event['state'] as int;
        debugPrint('[BandSession] connectionState event: state=$state');
        if (state == 0) { // Code.STATUS_DISCONNECT
            _handleDisconnect();
        } else if (state == 1 || state == 2) { // Code.STATUS_CONNECTED
            _emit(_state.copyWith(
              connectionStatus: BleConnectionStatus.connected,
              clearError: true,
            ));
            // Do NOT call _runInitPhase() here. Wait for notifyState.
        }
        break;
      case 'notifyState':
        debugPrint('[BandSession] notifyState event received → starting init phase');
        // Fallback: ensure the connection status is set to connected so the scheduler runs
        _emit(_state.copyWith(
          connectionStatus: BleConnectionStatus.connected,
          clearError: true,
        ));
        _runInitPhase();
        break;
      case 'heartRate':
        final hrVal = event['value'] as int;
        final isValid = hrVal > 20 && hrVal < 250;
        debugPrint('[BandSession] ❤️  heartRate=$hrVal (valid: $isValid)');
        if (isValid) {
          _onValidVitalsReceived('HR $hrVal bpm');
          _consistencyTracker.recordVitalReading('hr', hrVal);
          _lastHrTime = DateTime.now();
          _rrEngine.addHeartRate(hrVal);
          _processHrvFromHeartRate(hrVal);

          final publishedRr = _rrEngine.pollValidatedRr();
          if (publishedRr != null) {
            _lastRrTime = publishedRr.timestamp;
            _emit(_state.copyWith(
              hr: hrVal,
              respiratoryRate: publishedRr.respiratoryRate,
              isRrValidated: publishedRr.isValidated,
              rrConfidence: publishedRr.confidence,
              rrSource: publishedRr.source,
              isRemoved: false,
            ));
          } else {
            _emit(_state.copyWith(hr: hrVal, isRemoved: false));
          }
        }
        break;
      case 'spo2':
        final spo2Val = event['value'] as int;
        final isValid = spo2Val > 50 && spo2Val <= 100;
        debugPrint('[BandSession] 🩸 spo2=$spo2Val (valid: $isValid)');
        if (isValid) {
          _onValidVitalsReceived('SpO2 $spo2Val%');
          _consistencyTracker.recordVitalReading('spo2', spo2Val);
          _lastSpo2Time = DateTime.now();
          _rrEngine.addSpo2(spo2Val);
          _emit(_state.copyWith(spo2: spo2Val, isRemoved: false));
        }
        break;
      case 'respiratoryRate':
        final rrVal = event['value'] as int? ?? 0;
        final isValid = rrVal >= 5 && rrVal <= 60;
        debugPrint('[BandSession] 🫁 respiratoryRate=$rrVal (valid: $isValid)');
        if (isValid) {
          _onValidVitalsReceived('RR $rrVal rpm');
          _consistencyTracker.recordVitalReading('rr', rrVal);
          _lastRrTime = DateTime.now();
          _rrEngine.addHardwareBreathRate(rrVal);
          final publishedRr = _rrEngine.pollValidatedRr(force: true);
          _emit(_state.copyWith(
            respiratoryRate: publishedRr?.respiratoryRate ?? rrVal,
            isRrValidated: publishedRr?.isValidated ?? true,
            rrConfidence: publishedRr?.confidence ?? 0.90,
            rrSource: publishedRr?.source ?? 'hardware_sensor',
            isRemoved: false,
          ));
        }
        break;
      case 'bloodPressure':
        final sys = event['sys'] as int;
        final dia = event['dia'] as int;
        // Veepoo SDK docs: systolic range [60-300], diastolic range [20-200]
        final isValid = sys >= 60 && dia >= 20;
        debugPrint('[BandSession] 💉 bp=$sys/$dia (valid: $isValid)');
        if (isValid) {
          _onValidVitalsReceived('BP $sys/$dia');
          _consistencyTracker.recordVitalReading('bp', sys);
          _lastBpTime = DateTime.now();
          _emit(_state.copyWith(systolic: sys, diastolic: dia, isRemoved: false));
        }
        break;
      case 'temperature':
        final tempVal = (event['value'] as num).toDouble();
        final tempBaseVal = (event['valueBase'] as num?)?.toDouble() ?? 0.0;
        debugPrint('[BandSession] 🌡️  bodyTemp=$tempVal skinTemp=$tempBaseVal');
        
        double? validBodyTemp;
        double? validSkinTemp;
        if (tempVal > 30.0 && tempVal < 45.0) {
          validBodyTemp = tempVal;
          _lastTempTime = DateTime.now();
          _consistencyTracker.recordVitalReading('temp', validBodyTemp);
        }
        if (tempBaseVal > 30.0 && tempBaseVal < 45.0) {
          validSkinTemp = tempBaseVal;
        }
        // Note: Temperature sensor does not measure pulse and retains heat after removal.
        // It must NOT reset _lastValidPulseTime or clear isRemoved.
        _emit(_state.copyWith(
          tempC: validBodyTemp ?? _state.tempC,
          tempSkin: validSkinTemp ?? _state.tempSkin,
        ));
        break;
      case 'sportData':
        final stepsVal = event['step'] as int? ?? 0;
        final disVal = (event['distance'] as num?)?.toDouble() ?? 0.0;
        final kcalVal = (event['calories'] as num?)?.toDouble() ?? 0.0;
        debugPrint('[BandSession] 🏃 sportData: steps=$stepsVal dis=$disVal kcal=$kcalVal');
        _rrEngine.addMotion(stepsVal);
        _emit(_state.copyWith(
          steps: stepsVal,
          distanceKm: disVal,
          calories: kcalVal,
        ));
        break;
      case 'hrv':
        final hrvVal = event['value'] as int? ?? 0;
        debugPrint('[BandSession] 💓 hrv=$hrvVal');
        if (hrvVal > 0) {
          _onValidVitalsReceived('HRV $hrvVal ms');
          _consistencyTracker.recordVitalReading('hrv', hrvVal);
          _lastHrvTime = DateTime.now();
          _rrEngine.addHrv(hrvVal);
          _emit(_state.copyWith(hrv: hrvVal, isRemoved: false));
        }
        break;
      case 'stress':
        final stressVal = event['value'] as int? ?? 0;
        debugPrint('[BandSession] ☯️ stress=$stressVal');
        if (stressVal > 0) {
          _onValidVitalsReceived('Stress $stressVal');
          _consistencyTracker.recordVitalReading('stress', stressVal);
          _lastStressTime = DateTime.now();
          _emit(_state.copyWith(stress: stressVal, isRemoved: false));
        }
        break;
      case 'battery':
        final batteryVal = event['value'] as int? ?? 0;
        debugPrint('[BandSession] 🔋 battery=$batteryVal%');
        if (batteryVal > 0) {
          _emit(_state.copyWith(battery: batteryVal));
        }
        break;
      case 'wearError':
        debugPrint('[BandSession] ℹ️ wearError event received (ignored in favor of multi-phase vital verification)');
        break;
      case 'checkWear':
        // Legacy event handler kept for compatibility
        final isRemovedVal = event['isRemoved'] as bool? ?? false;
        if (isRemovedVal && !_state.isRemoved) {
          _confirmBandRemoved('checkWear');
        }
        break;
      case 'sleepData':
        final total = event['totalSleepMinutes'] as int? ?? 0;
        final deep = event['deepSleepMinutes'] as int? ?? 0;
        final light = event['lightSleepMinutes'] as int? ?? 0;
        final rem = event['remSleepMinutes'] as int? ?? 0;
        final wake = event['wakeCount'] as int? ?? 0;
        final quality = event['sleepQuality'] as int? ?? 0;
        debugPrint('[BandSession] 😴 sleepData total=$total deep=$deep light=$light rem=$rem wake=$wake quality=$quality');
        _emit(_state.copyWith(
          totalSleepMinutes: total,
          deepSleepMinutes: deep,
          lightSleepMinutes: light,
          remSleepMinutes: rem,
          wakeCount: wake,
          sleepQuality: quality,
        ));
        break;
      case 'ecgState':
        final progress = event['progress'] as int? ?? 0;
        final statusName = event['deviceStatus'] as String? ?? '';
        final unpassWear = event['unpassWear'] as bool? ?? false;
        final hrVal = event['hr'] as int? ?? 0;
        final hrvVal = event['hrv'] as int? ?? 0;

        String? msg;
        if (unpassWear) {
          msg = 'Touch lost - Place index finger firmly on top electrode';
        } else if (statusName == 'KEEP_QUIT') {
          msg = 'Measuring... Keep still and stay calm';
        } else if (statusName == 'BUSY') {
          msg = 'Device busy... Please wait';
        } else if (progress >= 100) {
          msg = 'ECG Analysis Complete';
        } else {
          msg = 'Measuring ECG ($progress%)';
        }

        final isDone = progress >= 100;
        final finalHr = hrVal > 0 ? hrVal : _state.hr;
        final finalHrv = hrvVal > 0 ? hrvVal : _state.hrv;

        EcgResultData? fallbackRes = _state.lastEcgResult;
        if (isDone && fallbackRes == null) {
          fallbackRes = EcgResultData(
            isSuccess: true,
            aveHeart: finalHr,
            aveHrv: finalHrv ?? 0,
            aveQt: 0,
            aveResRate: 0,
            diseaseResult: 0,
            timestamp: DateTime.now(),
          );
        }

        _emit(_state.copyWith(
          isEcgMeasuring: !isDone,
          ecgProgress: progress,
          unpassWear: unpassWear,
          ecgStatusMessage: msg,
          hr: finalHr,
          hrv: finalHrv,
          lastEcgResult: fallbackRes,
        ));

        if (isDone) {
          try {
            _sdk.stopDetectEcg();
          } catch (_) {}
          _resumeAfterEcg();
        }
        break;
      case 'ecgAdc':
        if (!_state.isEcgMeasuring) break;
        final rawAdc = (event['adc'] as List<dynamic>?)?.map((e) => e as int).toList() ?? [];
        if (rawAdc.isNotEmpty) {
          final updatedPoints = List<int>.from(_state.ecgAdcPoints)..addAll(rawAdc);
          if (updatedPoints.length > 300) {
            updatedPoints.removeRange(0, updatedPoints.length - 300);
          }
          _emit(_state.copyWith(ecgAdcPoints: updatedPoints));
        }
        break;
      case 'ecgResult':
        final isSuccess = event['isSuccess'] as bool? ?? false;
        final aveHeart = event['aveHeart'] as int? ?? 0;
        final aveHrv = event['aveHrv'] as int? ?? 0;
        final aveQt = event['aveQt'] as int? ?? 0;
        final aveResRate = event['aveResRate'] as int? ?? 0;
        final diseaseResult = event['diseaseResult'] as int? ?? 0;

        final res = EcgResultData(
          isSuccess: isSuccess,
          aveHeart: aveHeart,
          aveHrv: aveHrv,
          aveQt: aveQt,
          aveResRate: aveResRate,
          diseaseResult: diseaseResult,
          timestamp: DateTime.now(),
        );

        _emit(_state.copyWith(
          isEcgMeasuring: false,
          ecgProgress: 100,
          lastEcgResult: res,
          hr: aveHeart > 0 ? aveHeart : _state.hr,
          hrv: aveHrv > 0 ? aveHrv : _state.hrv,
        ));

        try {
          _sdk.stopDetectEcg();
        } catch (_) {}
        _resumeAfterEcg();
        break;
      case 'ecgDiagnosis':
        final diseaseRisk = event['diseaseRisk'] as int? ?? 0;
        final pressureIndex = event['pressureIndex'] as int? ?? 0;
        final fatigueIndex = event['fatigueIndex'] as int? ?? 0;
        final myocarditisRisk = event['myocarditisRisk'] as int? ?? 0;
        final chdRisk = event['chdRisk'] as int? ?? 0;
        final angioscleroticRisk = event['angioscleroticRisk'] as int? ?? 0;

        final diag = EcgDiagnosisData(
          diseaseRisk: diseaseRisk,
          pressureIndex: pressureIndex,
          fatigueIndex: fatigueIndex,
          myocarditisRisk: myocarditisRisk,
          chdRisk: chdRisk,
          angioscleroticRisk: angioscleroticRisk,
        );

        _emit(_state.copyWith(
          lastEcgDiagnosis: diag,
          stress: pressureIndex > 0 ? pressureIndex : _state.stress,
        ));
        break;
      case 'originVitalsHistory':
        final rawRecords = event['records'] as List<dynamic>?;
        if (rawRecords != null && rawRecords.isNotEmpty) {
          final mapped = rawRecords.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          debugPrint('[BandSession] 📦 Received ${mapped.length} historical 5-minute vitals from band');
          onHistoryRecords?.call(mapped);
        }
        break;
      case 'originHrvHistory':
      case 'originSpo2History':
        final rawRecords = event['records'] as List<dynamic>?;
        if (rawRecords != null && rawRecords.isNotEmpty) {
          final mapped = rawRecords.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          debugPrint('[BandSession] 📦 Received ${mapped.length} auxiliary history items ($type) from band');
          onHistoryRecords?.call(mapped);
        }
        break;
      case 'originDataComplete':
        debugPrint('[BandSession] 🏁 Band historical data reading complete');
        if (_historyReadCompleter != null && !_historyReadCompleter!.isCompleted) {
          _historyReadCompleter!.complete();
        }
        onHistoryComplete?.call();
        break;
      default:
        debugPrint('[BandSession] Unknown event type: $type, data=$event');
        break;
    }
  }

  Timer? _schedulerTimer;
  int _cyclePhase = 0;

  void _runInitPhase() async {
    debugPrint('[BandSession] ── INIT PHASE START ──');

    debugPrint('[BandSession] Step 1: confirmDevicePwd...');
    final ok = await _sdk.confirmDevicePwd("0000");
    debugPrint('[BandSession] Step 1 result: pwd=${ok ? "✅ OK" : "❌ FAILED"}');
    if (!ok) {
        debugPrint('[BandSession] ❌ Password verification failed! Aborting init.');
        return;
    }
    
    debugPrint('[BandSession] Step 2: syncPersonInfo sex=${_personalInfo.sex} height=${_personalInfo.heightCm} weight=${_personalInfo.weightKg} age=${_personalInfo.age}');
    final infoOk = await _sdk.syncPersonInfo(
      sex: _personalInfo.sex,
      height: _personalInfo.heightCm,
      weight: _personalInfo.weightKg,
      age: _personalInfo.age,
      targetStep: 8000,
    );
    debugPrint('[BandSession] Step 2 result: personInfo=${infoOk ? "✅ OK" : "⚠️ FAILED (non-fatal)"}');
    
    try {
      debugPrint('[BandSession] Step 3: Enabling 24/7 background auto detection (SpO2, RR, Temp, BP, HRV)...');
      await _sdk.enableAutoDetectSettings();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      debugPrint('[BandSession] Step 4: Reading battery level...');
      await _sdk.readBattery();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      debugPrint('[BandSession] Step 5: Reading step counter...');
      await _sdk.readSportStep();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      debugPrint('[BandSession] Step 6: Reading 5-minute historical origin vitals from band (all days)...');
      _historyReadCompleter = Completer<void>();
      await _sdk.readOriginData(day: -1);
      // Wait for historical dump to complete before starting live rotation so BLE bus is quiet
      try {
        await _historyReadCompleter?.future.timeout(const Duration(seconds: 15));
      } catch (_) {
        debugPrint('[BandSession] ⏱ Historical read wait finished/timed out; starting live scheduler');
      }
    } catch (e) {
      debugPrint('[BandSession] Error reading init status/vitals: $e');
    }

    // Start watchdog timer and sequential rotation scheduler
    _lastValidPulseTime = DateTime.now();
    _watchdogTimer?.cancel();
    _watchdogTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _tickWatchdog());
    _startScheduler();

    // Start Personal Baseline evaluation timer
    _recalculatePersonalBaseline();
    _baselineTimer?.cancel();
    _baselineTimer = Timer.periodic(profileConfig.personalBaselineInterval, (_) {
      _recalculatePersonalBaseline();
    });

    // ── HR ingest timer: periodic ingest ──────────────────────────────────
    // Ingests the current BandState to cloud & DB without interrupting active BLE sensors.
    _hrIngestTimer?.cancel();
    _hrIngestTimer = Timer.periodic(scheduleDurations.ingestInterval, (_) async {
      if (_state.connectionStatus == BleConnectionStatus.connected) {
        try {
          debugPrint('[BandSession] ⏱ Routine ingest (${scheduleDurations.ingestInterval.inSeconds}s): hr=${_state.hr} spo2=${_state.spo2} rr=${_state.respiratoryRate} temp=${_state.tempC} bp=${_state.systolic}/${_state.diastolic} hrv=${_state.hrv} stress=${_state.stress} steps=${_state.steps} battery=${_state.battery}% isRemoved=${_state.isRemoved} sleep=${_state.totalSleepMinutes}m');
          await onIngest(_state);
        } catch (e) {
          debugPrint('[BandSession] ⚠️ Error during routine ingest: $e');
        }
      }
    });

    debugPrint('[BandSession] ── INIT PHASE COMPLETE ──');
  }

  List<_MeasurementPhase> _getPhases() {
    final phases = <_MeasurementPhase>[
      _MeasurementPhase(
        name: 'Heart Rate & HRV',
        duration: scheduleDurations.hrHrvDuration,
        start: () async {
          await _sdk.stopDetectSPO2();
          await _sdk.stopDetectBP();
          await _sdk.stopDetectTemp();
          await _sdk.stopDetectPressure();
          await _sdk.stopDetectBreath();
          await _sdk.stopDetectHeart();
          await Future.delayed(const Duration(milliseconds: 600));
          await _sdk.startDetectHeart();
        },
        stop: () async {
          await _sdk.stopDetectHeart();
        },
      ),
      _MeasurementPhase(
        name: 'SpO2',
        duration: scheduleDurations.spo2Duration,
        start: () async {
          await _sdk.stopDetectHeart();
          await _sdk.stopDetectBP();
          await _sdk.stopDetectTemp();
          await _sdk.stopDetectPressure();
          await _sdk.stopDetectBreath();
          await _sdk.stopDetectSPO2();
          await Future.delayed(const Duration(milliseconds: 600));
          await _sdk.startDetectSPO2();
        },
        stop: () async {
          await _sdk.stopDetectSPO2();
        },
      ),
      _MeasurementPhase(
        name: 'Respiration',
        duration: scheduleDurations.breathDuration,
        start: () async {
          await _sdk.stopDetectHeart();
          await _sdk.stopDetectSPO2();
          await _sdk.stopDetectBP();
          await _sdk.stopDetectTemp();
          await _sdk.stopDetectPressure();
          await _sdk.stopDetectBreath();
          await Future.delayed(const Duration(milliseconds: 600));
          await _sdk.startDetectBreath();
        },
        stop: () async {
          await _sdk.stopDetectBreath();
          final published = _rrEngine.pollValidatedRr(force: true);
          if (published != null) {
            _lastRrTime = published.timestamp;
            _emit(_state.copyWith(
              respiratoryRate: published.respiratoryRate,
              isRrValidated: published.isValidated,
              rrConfidence: published.confidence,
              rrSource: published.source,
            ));
          }
        },
      ),
      _MeasurementPhase(
        name: 'Temperature',
        duration: scheduleDurations.tempDuration,
        start: () async {
          await _sdk.stopDetectHeart();
          await _sdk.stopDetectSPO2();
          await _sdk.stopDetectBP();
          await _sdk.stopDetectPressure();
          await _sdk.stopDetectBreath();
          await _sdk.stopDetectTemp();
          await Future.delayed(const Duration(milliseconds: 600));
          await _sdk.startDetectTemp();
        },
        stop: () async {
          await _sdk.stopDetectTemp();
        },
      ),
    ];

    if (profileConfig.bpMode == BpMeasurementMode.nurseConfigurable) {
      phases.add(_MeasurementPhase(
        name: 'Blood Pressure',
        duration: scheduleDurations.bpDuration,
        start: () async {
          await _sdk.stopDetectHeart();
          await _sdk.stopDetectSPO2();
          await _sdk.stopDetectTemp();
          await _sdk.stopDetectPressure();
          await _sdk.stopDetectBreath();
          await _sdk.stopDetectBP();
          await Future.delayed(const Duration(milliseconds: 600));
          await _sdk.startDetectBP();
        },
        stop: () async {
          await _sdk.stopDetectBP();
        },
      ));
    }

    phases.add(_MeasurementPhase(
      name: 'Stress',
      duration: scheduleDurations.stressDuration,
      start: () async {
        await _sdk.stopDetectHeart();
        await _sdk.stopDetectSPO2();
        await _sdk.stopDetectBP();
        await _sdk.stopDetectTemp();
        await _sdk.stopDetectBreath();
        await _sdk.stopDetectPressure();
        await Future.delayed(const Duration(milliseconds: 600));
        await _sdk.startDetectPressure();
      },
      stop: () async {
        await _sdk.stopDetectPressure();
      },
    ));

    return phases;
  }

  void _startScheduler() async {
    _schedulerTimer?.cancel();
    _cyclePhase = 0;
    // Allow BLE bus to settle for 500ms before starting Phase 0 (Heart Rate & HRV)
    await Future.delayed(const Duration(milliseconds: 500));
    _runNextPhase();
  }

  void _runNextPhase() async {
    if (_state.connectionStatus != BleConnectionStatus.connected) return;

    final phases = _getPhases();
    final current = phases[_cyclePhase % phases.length];
    debugPrint('[BandSession] 🔄 Scheduler Phase: ${current.name} (duration: ${current.duration.inSeconds}s)');
    _currentPhaseHadValidVital = false;
    _consistencyTracker.recordPhaseStart(current.name, current.duration);
    
    try {
      await current.start();
    } catch (e) {
      debugPrint('[BandSession] Error starting phase ${current.name}: $e');
    }

    _schedulerTimer?.cancel();
    _schedulerTimer = Timer(current.duration, () async {
      try {
        await current.stop();
      } catch (e) {
        debugPrint('[BandSession] Error stopping phase ${current.name}: $e');
      }

      // Check if this phase recorded valid vitals (skip Temperature as it is non-pulsatile)
      if (current.name != 'Temperature') {
        if (!_currentPhaseHadValidVital) {
          _consecutiveFailedPhases++;
          debugPrint('[BandSession] ⚠️ Phase ${current.name} ended with NO valid vitals (consecutive failed phases: $_consecutiveFailedPhases)');
          final elapsed = DateTime.now().difference(_lastValidPulseTime).inSeconds;
          // Require at least 4 consecutive failed pulsatile phases AND >= 180s elapsed
          if (_consecutiveFailedPhases >= 4 && elapsed >= 180 && !_state.isRemoved) {
            _confirmBandRemoved('no vitals across $_consecutiveFailedPhases consecutive phases (${elapsed}s elapsed)');
          }
        } else {
          _consecutiveFailedPhases = 0;
        }
      }

      // Record consistency metrics for completed phase
      _consistencyTracker.recordPhaseEnd(current.name, hadValidVital: _currentPhaseHadValidVital);

      // Trigger an immediate ingest after each phase completes to persist new values right away
      if (_state.connectionStatus == BleConnectionStatus.connected) {
        try {
          debugPrint('[BandSession] ⏱ Immediate ingest post-${current.name} completion');
          await onIngest(_state);
        } catch (e) {
          debugPrint('[BandSession] ⚠️ Ingest error post-phase: $e');
        }
      }

      _cyclePhase++;
      if (_cyclePhase % phases.length == 0) {
        _consistencyTracker.recordCycleCompleted(
          hr: _state.hr,
          spo2: _state.spo2,
          tempC: _state.tempC,
          bpSys: _state.systolic,
          bpDia: _state.diastolic,
        );
        // Between full measurement cycles: refresh battery and steps safely without heavy sleep dump
        try {
          await _sdk.readBattery();
          await _sdk.readSportStep();
        } catch (_) {}
      }
      _runNextPhase();
    });
  }

  Future<void> disconnect() async {
    await _sdk.disconnect();
    _handleDisconnect();
  }

  void _emit(BandState s) {
    _state = s;
    if (!_controller.isClosed) {
      _controller.add(_state);
    }
  }

  void _handleDisconnect() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _wearErrorConfirmTimer?.cancel();
    _wearErrorConfirmTimer = null;
    _baselineTimer?.cancel();
    _baselineTimer = null;
    _hrIngestTimer?.cancel();
    _otherTimer?.cancel();
    _schedulerTimer?.cancel();
    if (_historyReadCompleter != null && !_historyReadCompleter!.isCompleted) {
      _historyReadCompleter!.complete();
    }
    _historyReadCompleter = null;
    _emit(_state.copyWith(connectionStatus: BleConnectionStatus.disconnected));
  }

  Future<void> startEcgMeasurement() async {
    if (_state.connectionStatus != BleConnectionStatus.connected) return;

    debugPrint('[BandSession] ⚡ Starting ECG Measurement - Pausing routine vitals rotation');
    _schedulerTimer?.cancel();
    try {
      await _sdk.stopDetectSPO2();
      await _sdk.stopDetectBP();
      await _sdk.stopDetectTemp();
      await _sdk.stopDetectPressure();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));

    _emit(_state.copyWith(
      isEcgMeasuring: true,
      ecgProgress: 0,
      unpassWear: false,
      ecgStatusMessage: 'Initializing ECG sensor...',
      clearEcgAdc: true,
    ));

    await _sdk.startDetectEcg();
  }

  Future<void> stopEcgMeasurement() async {
    debugPrint('[BandSession] 🛑 Stopping ECG Measurement');
    try {
      await _sdk.stopDetectEcg();
    } catch (_) {}
    _emit(_state.copyWith(isEcgMeasuring: false));
    _resumeAfterEcg();
  }

  void _resumeAfterEcg() async {
    debugPrint('[BandSession] 🔄 Resuming routine vitals rotation post-ECG');
    await Future.delayed(const Duration(milliseconds: 500));
    if (_state.connectionStatus == BleConnectionStatus.connected && !_state.isEcgMeasuring) {
      _startScheduler();
    }
  }

  void dispose() {
    disconnect();
    _eventSub?.cancel();
    _controller.close();
  }
}

class _MeasurementPhase {
  final String name;
  final Duration duration;
  final Future<void> Function() start;
  final Future<void> Function() stop;

  _MeasurementPhase({
    required this.name,
    required this.duration,
    required this.start,
    required this.stop,
  });
}
