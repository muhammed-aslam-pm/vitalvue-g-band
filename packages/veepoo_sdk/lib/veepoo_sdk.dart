import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
typedef VeepooErrorHandler = void Function(
  Object error,
  StackTrace stackTrace, {
  String? action,
  Map<String, dynamic>? context,
});

class VeepooSdk {
  static VeepooErrorHandler? onError;
  static const MethodChannel _channel = MethodChannel('veepoo_methods');
  static const EventChannel _eventChannel = EventChannel('veepoo_events');

  final StreamController<Map<String, dynamic>> _eventsController = StreamController<Map<String, dynamic>>.broadcast();

  VeepooSdk() {
    _eventChannel.receiveBroadcastStream().listen((dynamic event) {
      if (event is String) {
        try {
          final data = jsonDecode(event) as Map<String, dynamic>;
          _eventsController.add(data);
        } catch (e, stackTrace) {
          debugPrint('Error parsing veepoo event: $e');
          onError?.call(e, stackTrace, action: 'parse_event', context: {'payload': event});
        }
      }
    });
  }

  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  Future<String?> getPlatformVersion() async {
    return 'Android';
  }

  Future<void> startScan() async {
    await _channel.invokeMethod<void>('startScan');
  }

  Future<void> stopScan() async {
    await _channel.invokeMethod<void>('stopScan');
  }

  Future<bool> connect(String macAddress) async {
    try {
      final result = await _channel.invokeMethod<bool>('connect', {'mac': macAddress});
      return result ?? false;
    } on PlatformException catch (e, stackTrace) {
      onError?.call(e, stackTrace, action: 'connect', context: {'mac': macAddress});
      return false;
    }
  }

  Future<bool> confirmDevicePwd(String pwd) async {
    final result = await _channel.invokeMethod<bool>('confirmDevicePwd', {'pwd': pwd});
    return result ?? false;
  }

  Future<bool> syncPersonInfo({
    required int sex,
    required int height,
    required int weight,
    required int age,
    required int targetStep,
  }) async {
    final result = await _channel.invokeMethod<bool>('syncPersonInfo', {
      'sex': sex,
      'height': height,
      'weight': weight,
      'age': age,
      'targetStep': targetStep,
    });
    return result ?? false;
  }

  Future<void> disconnect() async {
    await _channel.invokeMethod<void>('disconnect');
  }

  Future<void> startDetectHeart() async {
    await _channel.invokeMethod<void>('startDetectHeart');
  }

  Future<void> stopDetectHeart() async {
    await _channel.invokeMethod<void>('stopDetectHeart');
  }

  Future<void> startDetectSPO2() async {
    await _channel.invokeMethod<void>('startDetectSPO2');
  }

  Future<void> stopDetectSPO2() async {
    await _channel.invokeMethod<void>('stopDetectSPO2');
  }

  Future<void> startDetectBP() async {
    await _channel.invokeMethod<void>('startDetectBP');
  }

  Future<void> stopDetectBP() async {
    await _channel.invokeMethod<void>('stopDetectBP');
  }

  Future<void> startDetectTemp() async {
    await _channel.invokeMethod<void>('startDetectTemp');
  }

  Future<void> stopDetectTemp() async {
    await _channel.invokeMethod<void>('stopDetectTemp');
  }

  Future<void> readSportStep() async {
    await _channel.invokeMethod<void>('readSportStep');
  }

  Future<void> startDetectHrv() async {
    await _channel.invokeMethod<void>('startDetectHrv');
  }

  Future<void> stopDetectHrv() async {
    await _channel.invokeMethod<void>('stopDetectHrv');
  }

  Future<void> startDetectPressure() async {
    await _channel.invokeMethod<void>('startDetectPressure');
  }

  Future<void> stopDetectPressure() async {
    await _channel.invokeMethod<void>('stopDetectPressure');
  }

  Future<void> readBattery() async {
    await _channel.invokeMethod<void>('readBattery');
  }

  Future<void> readCheckWear() async {
    await _channel.invokeMethod<void>('readCheckWear');
  }

  Future<void> startDetectBreath() async {
    await _channel.invokeMethod<void>('startDetectBreath');
  }

  Future<void> stopDetectBreath() async {
    await _channel.invokeMethod<void>('stopDetectBreath');
  }

  Future<void> readSleepData() async {
    await _channel.invokeMethod<void>('readSleepData');
  }

  Future<void> readSpo2hOrigin({int day = 0}) async {
    await _channel.invokeMethod<void>('readSpo2hOrigin', {'day': day});
  }

  Future<void> readOriginData({int day = 0}) async {
    await _channel.invokeMethod<void>('readOriginData', {'day': day});
  }

  Future<void> enableAutoDetectSettings() async {
    await _channel.invokeMethod<void>('enableAutoDetectSettings');
  }

  Future<void> startDetectEcg() async {
    await _channel.invokeMethod<void>('startDetectEcg');
  }

  Future<void> stopDetectEcg() async {
    await _channel.invokeMethod<void>('stopDetectEcg');
  }
}
