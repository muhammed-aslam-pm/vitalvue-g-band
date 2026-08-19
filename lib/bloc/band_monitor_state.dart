import 'package:equatable/equatable.dart';

import '../protocol/veepoo_protocol.dart';

class VpScanResult {
  final String mac;
  final String name;
  VpScanResult(this.mac, this.name);
}

abstract class BandMonitorState extends Equatable {
  const BandMonitorState();
}

/// App just launched — idle.
class BandIdleState extends BandMonitorState {
  const BandIdleState();
  @override
  List<Object?> get props => [];
}

/// BLE scan is active, listing nearby devices.
class BandScanningState extends BandMonitorState {
  final List<VpScanResult> results;
  const BandScanningState({this.results = const []});

  BandScanningState copyWith({List<VpScanResult>? results}) =>
      BandScanningState(results: results ?? this.results);

  @override
  List<Object?> get props => [results];
}

/// Attempting to connect to a device.
class BandConnectingState extends BandMonitorState {
  final String deviceName;
  const BandConnectingState(this.deviceName);
  @override
  List<Object?> get props => [deviceName];
}

/// Connected and streaming — the live-monitoring state.
class BandConnectedState extends BandMonitorState {
  final BandState vitals;
  const BandConnectedState(this.vitals);

  BandConnectedState copyWith({BandState? vitals}) =>
      BandConnectedState(vitals ?? this.vitals);

  @override
  List<Object?> get props => [vitals];
}

/// Disconnected (either by user or unexpectedly).
class BandDisconnectedState extends BandMonitorState {
  final String? reason;
  const BandDisconnectedState({this.reason});
  @override
  List<Object?> get props => [reason];
}
