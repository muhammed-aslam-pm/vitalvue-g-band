import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:veepoo_sdk/veepoo_sdk.dart';

import '../cloud/band_vitals_api.dart';
import '../protocol/veepoo_protocol.dart';
import '../session/band_session_service.dart';
import 'band_monitor_event.dart';
import 'band_monitor_state.dart';

// ── Internal events (private, never exposed to UI) ────────────────────────────

/// Fired by the session service whenever the band state changes.
/// Using add() instead of emit() from a subscription is the correct BLoC
/// pattern — emit() must only be called within an active event handler.
final class _BandStateUpdated extends BandMonitorEvent {
  final BandState state;
  const _BandStateUpdated(this.state);
  @override
  List<Object?> get props => [state];
}

/// Fired by the scan stream for each new result.
final class _ScanResultReceived extends BandMonitorEvent {
  final VpScanResult result;
  const _ScanResultReceived(this.result);
  @override
  List<Object?> get props => [result.mac];
}

// ── BLoC ──────────────────────────────────────────────────────────────────────

/// Bridges [BandSessionService] ↔ UI.
///
/// Key design rule (flutter_bloc):
///   emit() may only be called inside an active async event handler.
///   Any external async event (stream subscription, timer callback) must
///   use add() to dispatch an internal event, never emit() directly.
class BandMonitorBloc extends Bloc<BandMonitorEvent, BandMonitorState> {
  BandMonitorBloc({
    required BandVitalsApi vitalsApi,
    required int patientId,
    required String deviceId,
    required PersonalInfo personalInfo,
  })  : _vitalsApi = vitalsApi,
        _patientId = patientId,
        _deviceId = deviceId,
        _personalInfo = personalInfo,
        super(const BandIdleState()) {
    on<StartScan>(_onStartScan);
    on<StopScan>(_onStopScan);
    on<ConnectToBand>(_onConnect);
    on<DisconnectBand>(_onDisconnect);
    on<UpdateBandContext>(_onUpdateBandContext);
    on<StartEcgMeasurement>((event, emit) async {
      final service = FlutterBackgroundService();
      if (await service.isRunning()) {
        service.invoke('startEcg');
      } else {
        await _sdk.startDetectEcg();
      }
    });
    on<StopEcgMeasurement>((event, emit) async {
      final service = FlutterBackgroundService();
      if (await service.isRunning()) {
        service.invoke('stopEcg');
      } else {
        await _sdk.stopDetectEcg();
      }
    });
    // Internal events — handled inline with lambdas for brevity.
    on<_ScanResultReceived>((event, emit) {
      if (state is BandScanningState) {
        final current = state as BandScanningState;
        // Deduplicate by mac.
        final seen = {
          for (final r in current.results) r.mac: r,
        };
        seen[event.result.mac] = event.result;
        emit(BandScanningState(results: seen.values.toList()));
      }
    });
    on<_BandStateUpdated>((event, emit) {
      final s = event.state;
      if (s.connectionStatus == BleConnectionStatus.disconnected) {
        emit(const BandDisconnectedState());
      } else {
        emit(BandConnectedState(s));
      }
    });

    // Listen to background service updates
    _bgSub = FlutterBackgroundService().on('vitals_update').listen((data) {
      if (data == null) return;
      
      BleConnectionStatus status;
      if (data['status'] == BleConnectionStatus.connected.name) {
        status = BleConnectionStatus.connected;
      } else if (data['status'] == BleConnectionStatus.connecting.name) {
        status = BleConnectionStatus.connecting;
      } else {
        status = BleConnectionStatus.disconnected;
      }

      EcgResultData? ecgResult;
      if (data['lastEcgResult'] != null) {
        final resMap = Map<String, dynamic>.from(data['lastEcgResult'] as Map);
        ecgResult = EcgResultData(
          isSuccess: resMap['isSuccess'] as bool? ?? false,
          aveHeart: resMap['aveHeart'] as int? ?? 0,
          aveHrv: resMap['aveHrv'] as int? ?? 0,
          aveQt: resMap['aveQt'] as int? ?? 0,
          aveResRate: resMap['aveResRate'] as int? ?? 0,
          diseaseResult: resMap['diseaseResult'] as int? ?? 0,
          timestamp: DateTime.tryParse(resMap['timestamp'] as String? ?? '') ?? DateTime.now(),
        );
      }

      EcgDiagnosisData? ecgDiag;
      if (data['lastEcgDiagnosis'] != null) {
        final diagMap = Map<String, dynamic>.from(data['lastEcgDiagnosis'] as Map);
        ecgDiag = EcgDiagnosisData(
          diseaseRisk: diagMap['diseaseRisk'] as int? ?? 0,
          pressureIndex: diagMap['pressureIndex'] as int? ?? 0,
          fatigueIndex: diagMap['fatigueIndex'] as int? ?? 0,
          myocarditisRisk: diagMap['myocarditisRisk'] as int? ?? 0,
          chdRisk: diagMap['chdRisk'] as int? ?? 0,
          angioscleroticRisk: diagMap['angioscleroticRisk'] as int? ?? 0,
        );
      }

      final rawAdc = (data['ecgAdcPoints'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList() ?? [];

      final state = BandState(
        connectionStatus: status,
        hr: data['hr'] as int? ?? 0,
        spo2: data['spo2'] as int? ?? 0,
        respiratoryRate: data['respiratoryRate'] as int? ?? 0,
        tempC: (data['tempC'] as num?)?.toDouble() ?? 0.0,
        tempSkin: (data['tempSkin'] as num?)?.toDouble() ?? 0.0,
        systolic: data['bpSys'] as int?,
        diastolic: data['bpDia'] as int?,
        hrv: data['hrv'] as int?,
        stress: data['stress'] as int?,
        steps: data['steps'] as int? ?? 0,
        calories: (data['calories'] as num?)?.toDouble() ?? 0.0,
        distanceKm: (data['distanceKm'] as num?)?.toDouble() ?? 0.0,
        battery: data['battery'] as int? ?? -1,
        isRemoved: data['isRemoved'] as bool? ?? false,

        isEcgMeasuring: data['isEcgMeasuring'] as bool? ?? false,
        ecgProgress: data['ecgProgress'] as int? ?? 0,
        unpassWear: data['unpassWear'] as bool? ?? false,
        ecgStatusMessage: data['ecgStatusMessage'] as String?,
        ecgAdcPoints: rawAdc,
        lastEcgResult: ecgResult,
        lastEcgDiagnosis: ecgDiag,
      );
      
      if (!isClosed) add(_BandStateUpdated(state));
    });
  }

  // ignore: unused_field
  final BandVitalsApi _vitalsApi;
  // ignore: unused_field
  int _patientId;
  final String _deviceId;
  // ignore: unused_field
  PersonalInfo _personalInfo;
  
  final VeepooSdk _sdk = VeepooSdk();

  StreamSubscription<Map<String, dynamic>?>? _bgSub;
  StreamSubscription<Map<String, dynamic>>? _scanSub;

  // ── Scan ──────────────────────────────────────────────────────────────────

  Future<void> _onStartScan(StartScan _, Emitter<BandMonitorState> emit) async {
    emit(const BandScanningState());
    await _scanSub?.cancel();

    // Listen to sdk events for scanResult
    _scanSub = _sdk.events.listen((event) {
      if (event['type'] == 'scanResult') {
        if (!isClosed) {
          add(_ScanResultReceived(VpScanResult(event['mac'], event['name'])));
        }
      }
    });

    await _sdk.startScan();
  }

  Future<void> _onStopScan(StopScan _, Emitter<BandMonitorState> emit) async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _sdk.stopScan();
    emit(const BandIdleState());
  }

  // ── Context ───────────────────────────────────────────────────────────────

  void _onUpdateBandContext(
    UpdateBandContext event,
    Emitter<BandMonitorState> emit,
  ) {
    _patientId = event.patientId;
    _personalInfo = event.personalInfo;
  }

  // ── Connect ───────────────────────────────────────────────────────────────

  Future<void> _onConnect(
      ConnectToBand event, Emitter<BandMonitorState> emit) async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _sdk.stopScan();

    emit(BandConnectingState(event.deviceName));
    
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
      // Give the background isolate time to register event listeners.
      await Future.delayed(const Duration(milliseconds: 800));
    }
    
    service.invoke('connectDevice', {
      'remote_id': event.macAddress,
      'device_id': _deviceId,
    });
  }

  // ── Disconnect ────────────────────────────────────────────────────────────

  Future<void> _onDisconnect(
      DisconnectBand _, Emitter<BandMonitorState> emit) async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _sdk.stopScan();
    FlutterBackgroundService().invoke('stopService');
    emit(const BandDisconnectedState());
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  @override
  Future<void> close() async {
    await _bgSub?.cancel();
    await _scanSub?.cancel();
    return super.close();
  }
}
