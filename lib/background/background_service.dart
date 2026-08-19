import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../auth/auth_token_store.dart';
import 'background_preferences.dart';
import '../cloud/vitals_sse_service.dart';
import '../cloud/sse_events.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import '../session/band_session_service.dart';
import '../protocol/veepoo_protocol.dart';
import '../auth/auth_repository.dart';
import '../auth/auth_interceptor.dart';
import '../cloud/band_vitals_api.dart';
import '../db/vitals_database.dart';

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'gband_monitor_service',
    'GBand Monitoring Service',
    description: 'Keeps the vital sync alive in the background.',
    importance: Importance.low,
  );

  const AndroidNotificationChannel alertChannel = AndroidNotificationChannel(
    'critical_alerts_channel',
    'Critical Alerts',
    description: 'Notifications for critical patient vitals',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    sound: RawResourceAndroidNotificationSound('warning_beep'),
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_bg_service_small'),
      ),
    );
  }

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(alertChannel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'gband_monitor_service',
      initialNotificationTitle: 'GBand Monitor',
      initialNotificationContent: 'Initializing...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final profile = await BackgroundPreferences.getProfile();
  if (profile != null && !profile.isPatient) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'GBand Monitoring',
        content: 'Listening for critical patient alerts...',
      );
    }

    final tokenStore = AuthTokenStore();
    const baseUrl = String.fromEnvironment('BAND_API_URL',
        defaultValue: 'https://vitalvue-api.genesysailabs.com');
    final sseService = VitalsSseService(baseUrl: baseUrl, tokenStore: tokenStore);

    StreamSubscription? sseSub;
    final Set<int> alertedEvents = {};

    Timer.periodic(const Duration(seconds: 15), (timer) async {
      final t = await tokenStore.accessToken;
      if (t == null) {
        sseSub?.cancel();
        service.stopSelf();
        return;
      }
    });

    sseSub = sseService.connect().listen((event) async {
      if (event is SseCriticalAlertEvent) {
        final alertId = event.alertId;
        if (alertedEvents.contains(alertId)) return;
        alertedEvents.add(alertId);

        final ttsEnabled = await BackgroundPreferences.getEnableTts();
        final pushEnabled = await BackgroundPreferences.getEnablePush();

        if (pushEnabled) {
          await flutterLocalNotificationsPlugin.show(
            id: event.alertId,
            title: 'CRITICAL ALERT: Patient ${event.patientId}',
            body: '${event.vitalType.toUpperCase()} is ${event.triggeredValue}',
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'critical_alerts_channel',
                'Critical Alerts',
                importance: Importance.max,
                priority: Priority.max,
              ),
            ),
          );
        }

        if (ttsEnabled) {
          final tts = FlutterTts();
          await tts.speak(
              "Alert. Patient ${event.patientId} has critical ${event.vitalType}. ${event.triggeredValue}.");
        }

        bool? hasVib = await Vibration.hasVibrator();
        if (hasVib == true) {
          Vibration.vibrate(pattern: [500, 1000, 500, 1000]);
        }
        
        final player = AudioPlayer();
        await player.play(AssetSource('sounds/warning_beep.wav'));
      }
    });

    service.on('stopService').listen((event) {
      sseSub?.cancel();
      service.stopSelf();
    });
  }
  BandSessionService? session;

  service.on('stopService').listen((event) async {
    await session?.disconnect();
    service.stopSelf();
  });

  service.on('connectDevice').listen((event) async {
    if (event == null) return;
    final remoteIdStr = event['remote_id'] as String;
    final deviceId = event['device_id'] as String;

    await BackgroundPreferences.saveDevice(deviceId, remoteIdStr, deviceId);
    await session?.disconnect();

    final profile = await BackgroundPreferences.getProfile();
    if (profile == null) return;

    session = BandSessionService(
      patientId: profile.id,
      deviceId: deviceId,
      personalInfo: PersonalInfo(
        age: profile.age ?? 30,
        sex: (profile.gender ?? 'Male') == 'Male' ? 1 : 0,
        heightCm: profile.height ?? 170,
        weightKg: profile.weight ?? 70,
        stepLengthCm: ((profile.height ?? 170) * 0.415).toInt(),
      ),
      onIngest: (state) async {
        final store = AuthTokenStore();
        final repo = AuthRepository(
            baseUrl: 'https://vitalvue-api.genesysailabs.com', store: store);
        final interceptor =
            AuthInterceptor(store: store, repository: repo, onLogout: () {});
        final api = BandVitalsApi(
          baseUrl: 'https://vitalvue-api.genesysailabs.com',
          authInterceptor: interceptor,
        );
        
        // Guard: Don't ingest/save completely empty vitals during warm-up or connection transition
        final sys = state.systolic ?? 0;
        if (state.hr == 0 && state.spo2 == 0 && state.tempC == 0.0 && state.tempSkin == 0.0 && sys == 0) {
          debugPrint('[Background] Skipping ingest: all vitals are zero');
          return;
        }

        final db = VitalsDatabase.instance;
        
        final vitalData = {
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'patient_id': profile.id,
          'device_id': deviceId,
          'hr': state.hr,
          'spo2': state.spo2,
          'tempC': state.tempC,
          'tempSkin': state.tempSkin,
          'bpSys': state.systolic ?? 0,
          'bpDia': state.diastolic ?? 0,
          'hrv': state.hrv ?? 0,
          'stress': (state.stress ?? 0).toString(),
          'steps': state.steps,
          'calories': state.calories,
          'distanceKm': state.distanceKm,
          'battery': state.battery,
          'isRemoved': state.isRemoved,
          'isIngested': 0,
        };

        final id = await db.insertVital(vitalData);

        final success = await api.ingest(
          patientId: profile.id,
          deviceId: deviceId,
          hr: state.hr,
          spo2: state.spo2,
          tempC: state.tempC,
          tempSkin: state.tempSkin,
          bpSys: state.systolic ?? 0,
          bpDia: state.diastolic ?? 0,
          hrv: state.hrv ?? 0,
          stress: (state.stress ?? 0).toString(),
          steps: state.steps,
          calories: state.calories,
          distanceKm: state.distanceKm,
          battery: state.battery,
          isRemoved: state.isRemoved,
          isConnected: state.connectionStatus == BleConnectionStatus.connected,
        );

        if (success) {
          await db.markAsIngested(id);
        }

        await db.deleteOldVitals();
      },
    );

    service.on('startEcg').listen((event) async {
      debugPrint('[Background] ⚡ Received startEcg command');
      await session?.startEcgMeasurement();
    });

    service.on('stopEcg').listen((event) async {
      debugPrint('[Background] 🛑 Received stopEcg command');
      await session?.stopEcgMeasurement();
    });

    session!.stateStream.listen((state) {
      service.invoke('vitals_update', {
        'status': state.connectionStatus.name,
        'hr': state.hr,
        'spo2': state.spo2,
        'tempC': state.tempC,
        'tempSkin': state.tempSkin,
        'bpSys': state.systolic,
        'bpDia': state.diastolic,
        'hrv': state.hrv,
        'stress': state.stress,
        'steps': state.steps,
        'calories': state.calories,
        'distanceKm': state.distanceKm,
        'battery': state.battery,
        'isRemoved': state.isRemoved,

        // ECG fields
        'isEcgMeasuring': state.isEcgMeasuring,
        'ecgProgress': state.ecgProgress,
        'unpassWear': state.unpassWear,
        'ecgStatusMessage': state.ecgStatusMessage,
        'ecgAdcPoints': state.ecgAdcPoints,
        'lastEcgResult': state.lastEcgResult != null
            ? {
                'isSuccess': state.lastEcgResult!.isSuccess,
                'aveHeart': state.lastEcgResult!.aveHeart,
                'aveHrv': state.lastEcgResult!.aveHrv,
                'aveQt': state.lastEcgResult!.aveQt,
                'aveResRate': state.lastEcgResult!.aveResRate,
                'diseaseResult': state.lastEcgResult!.diseaseResult,
                'timestamp': state.lastEcgResult!.timestamp.toIso8601String(),
              }
            : null,
        'lastEcgDiagnosis': state.lastEcgDiagnosis != null
            ? {
                'diseaseRisk': state.lastEcgDiagnosis!.diseaseRisk,
                'pressureIndex': state.lastEcgDiagnosis!.pressureIndex,
                'fatigueIndex': state.lastEcgDiagnosis!.fatigueIndex,
                'myocarditisRisk': state.lastEcgDiagnosis!.myocarditisRisk,
                'chdRisk': state.lastEcgDiagnosis!.chdRisk,
                'angioscleroticRisk': state.lastEcgDiagnosis!.angioscleroticRisk,
              }
            : null,
      });

      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: state.connectionStatus == BleConnectionStatus.connected
              ? 'GBand Connected'
              : 'GBand Monitoring',
          content: state.connectionStatus == BleConnectionStatus.connected
              ? 'HR: ${state.hr} bpm | Body: ${state.tempC}°C | Skin: ${state.tempSkin}°C'
              : 'Connecting...',
        );
      }
    });

    final connected = await session!.connect(remoteIdStr);
    if (connected) {
      try {
        final store = AuthTokenStore();
        final repo = AuthRepository(
            baseUrl: 'https://vitalvue-api.genesysailabs.com', store: store);
        final interceptor =
            AuthInterceptor(store: store, repository: repo, onLogout: () {});
        final api = BandVitalsApi(
          baseUrl: 'https://vitalvue-api.genesysailabs.com',
          authInterceptor: interceptor,
        );
        api.changeDevice(deviceId).then((success) {
          if (success) {
            debugPrint('[Background] Successfully registered device $deviceId to patient');
          }
        }).catchError((e) {
          debugPrint('[Background] Error calling changeDevice: $e');
        });
      } catch (_) {}
    }
  });

  final savedDevice = await BackgroundPreferences.getDevice();
  if (savedDevice != null) {
    service.invoke('connectDevice', {
      'remote_id': savedDevice['mac'],
      'device_id': savedDevice['id'],
    });
  }
}
