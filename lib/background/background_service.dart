import 'dart:async';
import 'dart:io';
import 'dart:ui';
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
      initialNotificationTitle: 'VitalVue Consumer',
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
  DartPluginRegistrant.ensureInitialized();

  // Set up notifications for background updates
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // ── Shared Alert pre-feedback: long vibration + warning beep ────────────────
  // Plays vibration and the bundled warning beep concurrently, then holds
  // 700 ms so users hear: [buzz + beep] → voice announcement.
  Future<void> triggerAlertFeedback() async {
    await Future.wait([
      // 1. Long double-buzz: 700 ms on, 150 ms off, 700 ms on.
      () async {
        try {
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            await Vibration.vibrate(pattern: [0, 700, 150, 700]);
          }
        } catch (_) {}
      }(),
      // 2. Play the bundled triple-beep warning tone.
      () async {
        try {
          final player = AudioPlayer();
          await player.setVolume(1.0);
          await player.play(AssetSource('sounds/warning_beep.wav'));
          // Wait for the beep to finish (~800 ms) then release.
          await Future.delayed(const Duration(milliseconds: 900));
          await player.dispose();
        } catch (_) {}
      }(),
    ]);
    // Brief pause so TTS voice doesn't overlap the beep tail.
    await Future.delayed(const Duration(milliseconds: 700));
  }

  // Safe notification display that falls back gracefully if raw sound resource is not present
  Future<void> safeShowNotification({
    required int id,
    required String title,
    required String body,
    NotificationDetails? notificationDetails,
  }) async {
    try {
      await flutterLocalNotificationsPlugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: notificationDetails,
      );
    } catch (e) {
      debugPrint('[Background] ⚠️ Custom notification error ($e), falling back to default...');
      try {
        await flutterLocalNotificationsPlugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'critical_alerts_channel',
              'Critical Alerts',
              importance: Importance.max,
              priority: Priority.max,
            ),
          ),
        );
      } catch (_) {}
    }
  }

  // Track currently active alert IDs that are being announced.
  final Set<int> activeAlertIds = {};

  // ── Alert announcement: Beep Beep + speech × 3, then a final Beep Beep ──────
  // Pattern: [Beep Beep] "<message>" [Beep Beep] "<message>" [Beep Beep] "<message>" [Beep Beep]
  Future<void> announceRepeat(
    FlutterTts tts,
    String message, {
    int? alertId,
    int times = 3,
  }) async {
    for (int i = 0; i < times; i++) {
      if (alertId != null && !activeAlertIds.contains(alertId)) {
        break;
      }
      // Play beep + vibration.
      await triggerAlertFeedback();
      if (alertId != null && !activeAlertIds.contains(alertId)) {
        break;
      }
      // Speak the message and wait until it finishes.
      final completer = Completer<void>();
      tts.setCompletionHandler(() {
        if (!completer.isCompleted) completer.complete();
      });
      await tts.speak(message);
      // Guard: resolve after 10 s max in case the completion handler isn't fired.
      await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );
      if (alertId != null && !activeAlertIds.contains(alertId)) {
        break;
      }
      // Small gap between repetitions.
      await Future.delayed(const Duration(milliseconds: 400));
    }
    // Final Beep Beep after the last repetition, only if not silenced/dismissed.
    if (alertId == null || activeAlertIds.contains(alertId)) {
      await triggerAlertFeedback();
    }
    if (alertId != null) {
      activeAlertIds.remove(alertId);
    }
  }

  // --- STAFF/DOCTOR SSE BACKGROUND LOGIC ---
  final profile = await BackgroundPreferences.getProfile();
  if (profile != null && !profile.isPatient) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'VitalVue Monitoring',
        content: 'Monitoring Vitals 24/7',
      );
    }

    final tokenStore = AuthTokenStore();
    final sseService = VitalsSseService(
      baseUrl: 'https://vitalvue-api.genesysailabs.com',
      tokenStore: tokenStore,
    );

    final flutterTts = FlutterTts();
    await flutterTts.setVolume(1.0);
    await flutterTts.setSpeechRate(0.5);

    // Helper to look up a patient name from cached preferences.
    Future<String> resolvePatientName(int patientId) async {
      final patientNames = await BackgroundPreferences.getPatientNames();
      return patientNames[patientId] ?? 'Patient $patientId';
    }

    // Helper to build the room string for a TTS announcement.
    String roomLabel(String wardName, String roomNumber) {
      if (roomNumber.isEmpty) return '';
      return '$wardName, Room $roomNumber';
    }

    final sseSubscription = sseService.connect().listen((event) async {
      if (event is SseCriticalAlertEvent) {
        final enableTts = await BackgroundPreferences.getEnableTts();
        final enablePush = await BackgroundPreferences.getEnablePush();

        final nameTxt = await resolvePatientName(event.patientId);
        final hasRoom = event.roomNumber.isNotEmpty;
        final roomTxt =
            hasRoom ? roomLabel(event.wardName, event.roomNumber) : '';
        final roomSuffix = hasRoom ? ' $roomTxt' : '';
        final roomTxtPush =
            hasRoom ? ' (${event.wardName} - Rm ${event.roomNumber})' : '';

        final alertId = event.alertId;
        activeAlertIds.add(alertId);

        final vt = event.vitalType.toLowerCase();
        final tv = event.triggeredValue.toLowerCase();
        debugPrint(
            '[SSE Alert] vitalType="${event.vitalType}" triggeredValue="${event.triggeredValue}" severity=${event.severity}');
        final isDisconnect = vt.contains('disconnect') ||
            vt.contains('outbound') ||
            vt.contains('out of range') ||
            vt.contains('bluetooth') ||
            vt.contains('connectivity') ||
            tv.contains('disconnect') ||
            tv.contains('outbound') ||
            tv.contains('out of range') ||
            tv.contains('bluetooth');
        final isBandRemoval =
            (vt.contains('band') && (vt.contains('remov') || vt.contains('off'))) ||
                (tv.contains('band') && (tv.contains('remov') || tv.contains('off')));

        // 1. Fire push notification immediately
        if (enablePush) {
          if (isDisconnect) {
            safeShowNotification(
              id: event.alertId,
              title: 'Patient Outbound: $nameTxt$roomTxtPush',
              body: 'Band is out of range or disconnected.',
              notificationDetails: const NotificationDetails(
                android: AndroidNotificationDetails(
                  'critical_alerts_channel',
                  'Critical Alerts',
                  icon: 'ic_bg_service_small',
                  importance: Importance.max,
                  priority: Priority.max,
                  enableVibration: false,
                  playSound: true,
                  sound: RawResourceAndroidNotificationSound('warning_beep'),
                ),
              ),
            );
          } else if (isBandRemoval) {
            safeShowNotification(
              id: event.alertId,
              title: 'Band Removed: $nameTxt$roomTxtPush',
              body: 'Patient band was detected off-wrist.',
              notificationDetails: const NotificationDetails(
                android: AndroidNotificationDetails(
                  'critical_alerts_channel',
                  'Critical Alerts',
                  icon: 'ic_bg_service_small',
                  importance: Importance.max,
                  priority: Priority.max,
                  enableVibration: false,
                  playSound: true,
                  sound: RawResourceAndroidNotificationSound('warning_beep'),
                ),
              ),
            );
          } else {
            safeShowNotification(
              id: event.alertId,
              title:
                  'Critical Alert: ${event.vitalType} ($nameTxt$roomTxtPush)',
              body:
                  'Value triggered: ${event.triggeredValue} (${event.severity})',
              notificationDetails: const NotificationDetails(
                android: AndroidNotificationDetails(
                  'critical_alerts_channel',
                  'Critical Alerts',
                  icon: 'ic_bg_service_small',
                  importance: Importance.max,
                  priority: Priority.max,
                  enableVibration: false,
                  playSound: true,
                  sound: RawResourceAndroidNotificationSound('warning_beep'),
                ),
              ),
            );
          }
        }

        // 2. Play TTS announcement (3× repeat)
        if (enableTts) {
          if (isDisconnect) {
            final ttsMsg = hasRoom
                ? 'Patient Outbound. $nameTxt,$roomSuffix is Outbound.'
                : 'Patient Outbound. $nameTxt is Outbound.';
            await announceRepeat(flutterTts, ttsMsg, alertId: alertId);
          } else if (isBandRemoval) {
            final ttsMsg = hasRoom
                ? 'Patient Band Removed. Please attend $nameTxt$roomSuffix.'
                : 'Patient Band Removed. Please attend $nameTxt.';
            await announceRepeat(flutterTts, ttsMsg, alertId: alertId);
          } else {
            await announceRepeat(
              flutterTts,
              'Patient Critical Alert. Please attend $nameTxt$roomSuffix immediately.',
              alertId: alertId,
            );
          }
        } else {
          await triggerAlertFeedback();
        }
      } else if (event is SseAlertSnoozedEvent) {
        debugPrint('[SSE Alert Snoozed] alertId=${event.alertId}');
        activeAlertIds.remove(event.alertId);
        await flutterTts.stop();
        try {
          await flutterLocalNotificationsPlugin.cancel(id: event.alertId);
        } catch (_) {}
      } else if (event is SseAlertResolvedEvent) {
        debugPrint('[SSE Alert Resolved] alertId=${event.alertId}');
        activeAlertIds.remove(event.alertId);
        await flutterTts.stop();
        try {
          await flutterLocalNotificationsPlugin.cancel(id: event.alertId);
        } catch (_) {}
      } else if (event is SseBluetoothDisconnectEvent) {
        final enableTts = await BackgroundPreferences.getEnableTts();
        final enablePush = await BackgroundPreferences.getEnablePush();

        final nameTxt = await resolvePatientName(event.patientId);
        final hasRoom = event.roomNumber.isNotEmpty;
        final roomTxt =
            hasRoom ? roomLabel(event.wardName, event.roomNumber) : '';
        final ttsMsg = hasRoom
            ? 'Patient Outbound. $nameTxt, $roomTxt is Outbound.'
            : 'Patient Outbound. $nameTxt is Outbound.';

        if (enablePush) {
          final roomTxtPush =
              hasRoom ? ' (${event.wardName} - Rm ${event.roomNumber})' : '';
          flutterLocalNotificationsPlugin.show(
            id: event.patientId * 10 + 1,
            title: 'Patient Outbound: $nameTxt$roomTxtPush',
            body: 'Band is out of range or disconnected.',
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'critical_alerts_channel',
                'Critical Alerts',
                icon: 'ic_bg_service_small',
                importance: Importance.max,
                priority: Priority.max,
                enableVibration: false,
                playSound: true,
                sound: RawResourceAndroidNotificationSound('warning_beep'),
              ),
            ),
          );
        }
        if (enableTts) {
          await announceRepeat(flutterTts, ttsMsg);
        } else {
          await triggerAlertFeedback();
        }
      } else if (event is SseBandRemovalEvent) {
        final enableTts = await BackgroundPreferences.getEnableTts();
        final enablePush = await BackgroundPreferences.getEnablePush();

        final nameTxt = await resolvePatientName(event.patientId);
        final hasRoom = event.roomNumber.isNotEmpty;
        final roomTxt =
            hasRoom ? roomLabel(event.wardName, event.roomNumber) : '';
        final ttsMsg = hasRoom
            ? 'Patient Band Removed. Please attend $nameTxt $roomTxt.'
            : 'Patient Band Removed. Please attend $nameTxt.';

        if (enablePush) {
          final roomTxtPush =
              hasRoom ? ' (${event.wardName} - Rm ${event.roomNumber})' : '';
          flutterLocalNotificationsPlugin.show(
            id: event.patientId * 10 + 2,
            title: 'Band Removed: $nameTxt$roomTxtPush',
            body: 'Patient band was detected off-wrist.',
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'critical_alerts_channel',
                'Critical Alerts',
                icon: 'ic_bg_service_small',
                importance: Importance.max,
                priority: Priority.max,
                enableVibration: false,
                playSound: true,
                sound: RawResourceAndroidNotificationSound('warning_beep'),
              ),
            ),
          );
        }
        if (enableTts) {
          await announceRepeat(flutterTts, ttsMsg);
        } else {
          await triggerAlertFeedback();
        }
      }
    });

    service.on('stopService').listen((event) async {
      await sseSubscription.cancel();
      service.stopSelf();
    });

    // Self-stopping watchdog on logout
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      final p = await BackgroundPreferences.getProfile();
      if (p == null) {
        timer.cancel();
        await sseSubscription.cancel();
        service.stopSelf();
      }
    });

    return;
  }
  // --- END STAFF/DOCTOR LOGIC ---

  // --- PATIENT BLE MONITORING LOGIC ---
  BandSessionService? session;

  final patientTts = FlutterTts();
  await patientTts.setVolume(1.0);
  await patientTts.setSpeechRate(0.5);

  bool wasConnected = false;
  bool isManualDisconnect = false;
  bool wasRemoved = false;
  Timer? patientBandRemovalTimer;

  service.on('stopService').listen((event) async {
    isManualDisconnect = true;
    patientBandRemovalTimer?.cancel();
    await session?.disconnect();
    service.stopSelf();
  });

  service.on('disconnectDevice').listen((event) async {
    isManualDisconnect = true;
    patientBandRemovalTimer?.cancel();
    await session?.disconnect();
  });

  service.on('connectDevice').listen((event) async {
    if (event == null) return;
    isManualDisconnect = false;
    wasRemoved = false;
    patientBandRemovalTimer?.cancel();

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
        if (state.hr == 0 &&
            state.spo2 == 0 &&
            state.tempC == 0.0 &&
            state.tempSkin == 0.0 &&
            sys == 0) {
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
          'respirationRate': state.respiratoryRate,
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
          respirationRate: state.respiratoryRate,
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

    session!.stateStream.listen((state) async {
      // Broadcast state back to UI
      service.invoke('vitals_update', {
        'status': state.connectionStatus.name,
        'hr': state.hr,
        'spo2': state.spo2,
        'respiratoryRate': state.respiratoryRate,
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

      final isConnected =
          state.connectionStatus == BleConnectionStatus.connected;
      final isDisconnected =
          state.connectionStatus == BleConnectionStatus.disconnected;

      // ── Accidental Disconnect Detection ──
      if (wasConnected && isDisconnected && !isManualDisconnect) {
        wasConnected = false;
        final enableAccidentalAlert =
            await BackgroundPreferences.getEnableAccidentalDisconnectAlert();

        if (enableAccidentalAlert) {
          final enableTts = await BackgroundPreferences.getEnableTts();
          final enablePush = await BackgroundPreferences.getEnablePush();

          if (enableTts) {
            await announceRepeat(patientTts,
                'Warning: Your band was disconnected accidentally. Attempting to reconnect.');
          } else {
            await triggerAlertFeedback();
          }

          if (enablePush) {
            safeShowNotification(
              id: 991,
              title: 'Band Disconnected',
              body:
                  'Your band lost connection accidentally. Attempting to reconnect...',
              notificationDetails: const NotificationDetails(
                android: AndroidNotificationDetails(
                  'critical_alerts_channel',
                  'Critical Alerts',
                  icon: 'ic_bg_service_small',
                  importance: Importance.max,
                  priority: Priority.max,
                  enableVibration: false,
                  playSound: true,
                  sound: RawResourceAndroidNotificationSound('warning_beep'),
                ),
              ),
            );
          }
        }
      } else if (isConnected) {
        wasConnected = true;
      }

      // ── Off-Wrist Detection ──
      if (!wasRemoved && state.isRemoved) {
        wasRemoved = true;
        patientBandRemovalTimer?.cancel();
        final enableTts = await BackgroundPreferences.getEnableTts();
        final enablePush = await BackgroundPreferences.getEnablePush();

        if (enableTts) {
          await announceRepeat(patientTts,
              'Warning: Band off wrist detected. Please put your band back on.');
        } else {
          await triggerAlertFeedback();
        }

        if (enablePush) {
          safeShowNotification(
            id: 992,
            title: 'Band Off-Wrist Detected',
            body: 'Please ensure your band is worn securely on your wrist.',
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'critical_alerts_channel',
                'Critical Alerts',
                icon: 'ic_bg_service_small',
                importance: Importance.max,
                priority: Priority.max,
                enableVibration: false,
                playSound: true,
                sound: RawResourceAndroidNotificationSound('warning_beep'),
              ),
            ),
          );
        }

        // Schedule 10-minute follow-up alert if band remains off-wrist
        patientBandRemovalTimer =
            Timer(const Duration(minutes: 10), () async {
          if (wasRemoved) {
            final followUpTts = await BackgroundPreferences.getEnableTts();
            final followUpPush = await BackgroundPreferences.getEnablePush();

            if (followUpTts) {
              await announceRepeat(patientTts,
                  'Follow-up Warning: Your band has been off-wrist for 10 minutes. Please put your band back on immediately.');
            } else {
              await triggerAlertFeedback();
            }

            if (followUpPush) {
              safeShowNotification(
                id: 993,
                title: 'Follow-Up: Band Still Off-Wrist',
                body:
                    'Your band has been off-wrist for over 10 minutes. Please re-wear it immediately.',
                notificationDetails: const NotificationDetails(
                  android: AndroidNotificationDetails(
                    'critical_alerts_channel',
                    'Critical Alerts',
                    icon: 'ic_bg_service_small',
                    importance: Importance.max,
                    priority: Priority.max,
                    enableVibration: false,
                    playSound: true,
                    sound: RawResourceAndroidNotificationSound('warning_beep'),
                  ),
                ),
              );
            }
          }
        });
      } else if (wasRemoved && !state.isRemoved) {
        wasRemoved = false;
        patientBandRemovalTimer?.cancel();
      }

      if (service is AndroidServiceInstance) {
        if (isConnected) {
          flutterLocalNotificationsPlugin.show(
            id: 888,
            title: 'GBand Connected',
            body:
                'HR: ${state.hr} bpm | Body: ${state.tempC}°C | Skin: ${state.tempSkin}°C',
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'gband_monitor_service',
                'GBand Monitoring Service',
                icon: 'ic_bg_service_small',
                ongoing: true,
              ),
            ),
          );
        } else {
          flutterLocalNotificationsPlugin.show(
            id: 888,
            title: 'GBand Disconnected',
            body: 'Attempting to reconnect...',
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'gband_monitor_service',
                'GBand Monitoring Service',
                icon: 'ic_bg_service_small',
                ongoing: true,
              ),
            ),
          );
        }
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
            debugPrint(
                '[Background] Successfully registered device $deviceId to patient');
          }
        }).catchError((e) {
          debugPrint('[Background] Error calling changeDevice: $e');
        });
      } catch (_) {}
    }
  });

  // Self-stopping watchdog on logout
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    final p = await BackgroundPreferences.getProfile();
    if (p == null) {
      timer.cancel();
      isManualDisconnect = true;
      patientBandRemovalTimer?.cancel();
      await session?.disconnect();
      service.stopSelf();
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
