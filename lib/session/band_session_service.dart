import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:veepoo_sdk/veepoo_sdk.dart';
import '../protocol/veepoo_protocol.dart';

class VitalsScheduleDurations {
  const VitalsScheduleDurations({
    this.spo2Duration = const Duration(seconds: 20),
    this.breathDuration = const Duration(seconds: 25),
    this.tempDuration = const Duration(seconds: 20),
    this.bpDuration = const Duration(seconds: 55),
    this.stressDuration = const Duration(seconds: 50),
    this.hrHrvDuration = const Duration(seconds: 130),
    this.ingestInterval = const Duration(seconds: 60),
  });

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
    this.scheduleDurations = const VitalsScheduleDurations(),
  }) : _personalInfo = personalInfo;

  final int patientId;
  final String deviceId;
  final PersonalInfo _personalInfo;
  final Future<void> Function(BandState state) onIngest;
  final VitalsScheduleDurations scheduleDurations;

  final VeepooSdk _sdk = VeepooSdk();

  BandState _state = const BandState();
  final _controller = StreamController<BandState>.broadcast();
  Stream<BandState> get stateStream => _controller.stream;
  BandState get currentState => _state;

  StreamSubscription? _eventSub;
  Timer? _hrIngestTimer;   // fires every 1 min → ingest current vitals
  Timer? _otherTimer;      // fires every 5 min → restart BP / SpO2 / Temp

  final List<double> _recentRrIntervals = [];

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
      if (_state.respiratoryRate <= 0 && !_state.isRemoved) {
        final estimatedRr = ((hr / 4.5).round()).clamp(12, 20);
        _emit(_state.copyWith(
          hrv: (rmssd > 10 && rmssd < 200) ? rmssd : _state.hrv,
          respiratoryRate: estimatedRr,
        ));
      } else if (rmssd > 10 && rmssd < 200) {
        _emit(_state.copyWith(hrv: rmssd));
      }
    }
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
        debugPrint('[BandSession] ❤️  heartRate=$hrVal (valid: ${hrVal > 20 && hrVal < 250})');
        if (hrVal > 20 && hrVal < 250) {
          // Valid HR → immediately clear off-wrist status in the same emit
          _emit(_state.copyWith(hr: hrVal, isRemoved: false));
          _processHrvFromHeartRate(hrVal);
        }
        break;
      case 'spo2':
        final spo2Val = event['value'] as int;
        debugPrint('[BandSession] 🩸 spo2=$spo2Val (valid: ${spo2Val > 50 && spo2Val <= 100})');
        if (spo2Val > 50 && spo2Val <= 100) {
          _emit(_state.copyWith(spo2: spo2Val));
        }
        break;
      case 'respiratoryRate':
        final rrVal = event['value'] as int? ?? 0;
        debugPrint('[BandSession] 🫁 respiratoryRate=$rrVal (valid: ${rrVal >= 5 && rrVal <= 60})');
        if (rrVal >= 5 && rrVal <= 60) {
          _emit(_state.copyWith(respiratoryRate: rrVal));
        }
        break;
      case 'bloodPressure':
        final sys = event['sys'] as int;
        final dia = event['dia'] as int;
        debugPrint('[BandSession] 💉 bp=$sys/$dia (valid: ${sys > 40 && dia > 20})');
        if (sys > 40 && dia > 20) {
          _emit(_state.copyWith(systolic: sys, diastolic: dia));
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
        }
        if (tempBaseVal > 30.0 && tempBaseVal < 45.0) {
          validSkinTemp = tempBaseVal;
        }
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
          _emit(_state.copyWith(hrv: hrvVal));
        }
        break;
      case 'stress':
        final stressVal = event['value'] as int? ?? 0;
        debugPrint('[BandSession] ☯️ stress=$stressVal');
        if (stressVal > 0) {
          _emit(_state.copyWith(stress: stressVal));
        }
        break;
      case 'battery':
        final batteryVal = event['value'] as int? ?? 0;
        debugPrint('[BandSession] 🔋 battery=$batteryVal%');
        if (batteryVal > 0) {
          _emit(_state.copyWith(battery: batteryVal));
        }
        break;
      case 'checkWear':
        final isRemovedVal = event['isRemoved'] as bool? ?? false;
        debugPrint('[BandSession] ⌚ checkWear isRemoved=$isRemovedVal');
        // Only emit for off-wrist (true) — on-wrist is handled in heartRate case
        if (isRemovedVal) {
          _emit(_state.copyWith(isRemoved: true));
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

      debugPrint('[BandSession] Step 6: Reading sleep data...');
      await _sdk.readSleepData();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      debugPrint('[BandSession] Step 7: Reading SpO2 & Respiration origin data...');
      await _sdk.readSpo2hOrigin();
      await Future<void>.delayed(const Duration(milliseconds: 600));
    } catch (e) {
      debugPrint('[BandSession] Error reading init status/vitals: $e');
    }

    // Start our sequential rotation scheduler
    _startScheduler();

    // ── HR ingest timer: periodic ingest ──────────────────────────────────
    // Ingests the current BandState to cloud & DB.
    _hrIngestTimer?.cancel();
    _hrIngestTimer = Timer.periodic(scheduleDurations.ingestInterval, (_) async {
      if (_state.connectionStatus == BleConnectionStatus.connected) {
        try {
          // Non-blocking quick reads (step, battery, sleep, SpO2/RR origin)
          await _sdk.readSportStep();
          await _sdk.readBattery();
          await _sdk.readSleepData();
          await _sdk.readSpo2hOrigin();
        } catch (e) {
          debugPrint('[BandSession] Error reading status/vitals: $e');
        }
        debugPrint('[BandSession] ⏱ Routine ingest (${scheduleDurations.ingestInterval.inSeconds}s): hr=${_state.hr} spo2=${_state.spo2} rr=${_state.respiratoryRate} temp=${_state.tempC} bp=${_state.systolic}/${_state.diastolic} hrv=${_state.hrv} stress=${_state.stress} steps=${_state.steps} battery=${_state.battery}% isRemoved=${_state.isRemoved} sleep=${_state.totalSleepMinutes}m');
        onIngest(_state);
      }
    });

    debugPrint('[BandSession] ── INIT PHASE COMPLETE ──');
  }

  void _startScheduler() {
    _schedulerTimer?.cancel();
    _cyclePhase = 0;
    _runNextPhase();
  }

  void _runNextPhase() async {
    if (_state.connectionStatus != BleConnectionStatus.connected) return;

    // Define sequential phases to prevent PPG green/red LED clashes.
    // Total cycle duration defaults to 300 seconds (5 minutes)
    // 0: SpO2 (25s) - Measures Blood Oxygen & Respiration Rate
    // 1: Temp (20s)
    // 2: BP (55s)
    // 3: Stress (50s)
    // 4: HR & Dynamic HRV (150s)
    final phases = [
      _MeasurementPhase(
        name: 'SpO2',
        duration: scheduleDurations.spo2Duration,
        start: () async {
          await _sdk.stopDetectHeart();
          await _sdk.stopDetectBP();
          await _sdk.stopDetectTemp();
          await _sdk.stopDetectPressure();
          await Future.delayed(const Duration(milliseconds: 300));
          await _sdk.startDetectSPO2();
        },
        stop: () async {
          await _sdk.stopDetectSPO2();
        },
      ),
      _MeasurementPhase(
        name: 'Temperature',
        duration: scheduleDurations.tempDuration,
        start: () async {
          await _sdk.stopDetectSPO2();
          await _sdk.stopDetectBP();
          await _sdk.stopDetectPressure();
          await Future.delayed(const Duration(milliseconds: 300));
          await _sdk.startDetectHeart();
          await _sdk.startDetectTemp();
        },
        stop: () async {
          await _sdk.stopDetectTemp();
        },
      ),
      _MeasurementPhase(
        name: 'Blood Pressure',
        duration: scheduleDurations.bpDuration,
        start: () async {
          await _sdk.stopDetectSPO2();
          await _sdk.stopDetectTemp();
          await _sdk.stopDetectPressure();
          await Future.delayed(const Duration(milliseconds: 300));
          await _sdk.startDetectHeart();
          await _sdk.startDetectBP();
        },
        stop: () async {
          await _sdk.stopDetectBP();
        },
      ),
      _MeasurementPhase(
        name: 'Stress',
        duration: scheduleDurations.stressDuration,
        start: () async {
          await _sdk.stopDetectSPO2();
          await _sdk.stopDetectBP();
          await _sdk.stopDetectTemp();
          await Future.delayed(const Duration(milliseconds: 300));
          await _sdk.startDetectHeart();
          await _sdk.startDetectPressure();
        },
        stop: () async {
          await _sdk.stopDetectPressure();
        },
      ),
      _MeasurementPhase(
        name: 'Heart Rate & HRV',
        duration: scheduleDurations.hrHrvDuration,
        start: () async {
          await _sdk.stopDetectSPO2();
          await _sdk.stopDetectBP();
          await _sdk.stopDetectTemp();
          await _sdk.stopDetectPressure();
          await Future.delayed(const Duration(milliseconds: 300));
          await _sdk.startDetectHeart();
        },
        stop: () async {
          // Keep HR running
        },
      ),
    ];

    final current = phases[_cyclePhase % phases.length];
    debugPrint('[BandSession] 🔄 Scheduler Phase: ${current.name} (duration: ${current.duration.inSeconds}s)');
    
    try {
      await current.start();
    } catch (e) {
      debugPrint('[BandSession] Error starting phase ${current.name}: $e');
    }

    _schedulerTimer = Timer(current.duration, () async {
      try {
        await current.stop();
      } catch (e) {
        debugPrint('[BandSession] Error stopping phase ${current.name}: $e');
      }

      // Trigger an immediate ingest after SpO2, Temp, BP, HRV or Stress completes to persist new values right away
      if (current.name != 'Heart Rate' && _state.connectionStatus == BleConnectionStatus.connected) {
        debugPrint('[BandSession] ⏱ Immediate ingest post-${current.name} completion');
        onIngest(_state);
      }

      _cyclePhase++;
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
    _hrIngestTimer?.cancel();
    _otherTimer?.cancel();
    _schedulerTimer?.cancel();
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
