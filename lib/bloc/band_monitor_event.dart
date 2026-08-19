import 'package:equatable/equatable.dart';

import '../protocol/veepoo_protocol.dart' show PersonalInfo;
abstract class BandMonitorEvent extends Equatable {
  const BandMonitorEvent();
}

class StartScan extends BandMonitorEvent {
  const StartScan();
  @override
  List<Object?> get props => [];
}

class StopScan extends BandMonitorEvent {
  const StopScan();
  @override
  List<Object?> get props => [];
}

class ConnectToBand extends BandMonitorEvent {
  final String macAddress;
  final String deviceName;
  const ConnectToBand(this.macAddress, this.deviceName);
  @override
  List<Object?> get props => [macAddress, deviceName];
}

class DisconnectBand extends BandMonitorEvent {
  const DisconnectBand();
  @override
  List<Object?> get props => [];
}

class UpdateBandContext extends BandMonitorEvent {
  final int patientId;
  final PersonalInfo personalInfo;
  
  const UpdateBandContext({
    required this.patientId,
    required this.personalInfo,
  });

  @override
  List<Object?> get props => [patientId, personalInfo];
}

class StartEcgMeasurement extends BandMonitorEvent {
  const StartEcgMeasurement();
  @override
  List<Object?> get props => [];
}

class StopEcgMeasurement extends BandMonitorEvent {
  const StopEcgMeasurement();
  @override
  List<Object?> get props => [];
}
