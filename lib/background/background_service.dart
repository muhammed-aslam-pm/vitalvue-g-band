import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sentry_flutter/sentry_flutter.dart';


import '../auth/auth_token_store.dart';
import '../config/vitalvue_config.dart';
import 'background_preferences.dart';
import '../cloud/vitals_sse_service.dart';
import '../cloud/sse_events.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import '../session/band_session_service.dart';
import 'package:veepoo_sdk/veepoo_sdk.dart';
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

  const defaultDsn =
      'https://dd4d1111c317b961e3f1f6e80430ea9a@o4512067849945088.ingest.us.sentry.io/4512067856105472';
  await SentryFlutter.init(
    (options) {
      options.dsn = const String.fromEnvironment('SENTRY_DSN', defaultValue: defaultDsn);
      options.tracesSampleRate = 1.0;
      options.enableFramesTracking = false;
      options.enableAutoSessionTracking = false;
    },
  );
  
  PlatformDispatcher.instance.onError = (error, stack) {
    Sentry.captureException(error, stackTrace: stack, withScope: (scope) => scope.setTag('isolate', 'background'));
    return true;
  };
  FlutterError.onError = (details) {
    Sentry.captureException(details.exception, stackTrace: details.stack, withScope: (scope) => scope.setTag('isolate', 'background'));
  };
  VeepooSdk.onError = (error, stack, {action, context}) {
    Sentry.captureException(
      error,
      stackTrace: stack,
      withScope: (scope) {
        scope.setTag('isolate', 'background');
        if (action != null) scope.setTag('action', action);
        if (context != null) scope.setContexts('veepoo', context);
      },
    );
  };

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

  bool wasConnected = false;
  bool isManualDisconnect = false;
  bool wasRemoved = false;
  Timer? patientBandRemovalTimer;

  service.on('stopService').listen((event) async {
    isManualDisconnect = true;
    service.invoke('sync_status', {
      'isSyncing': false,
      'pending': 0,
    });
    patientBandRemovalTimer?.cancel();
    await session?.disconnect();
    service.stopSelf();
  });

  service.on('disconnectDevice').listen((event) async {
    isManualDisconnect = true;
    Sentry.addBreadcrumb(Breadcrumb(
      message: 'Manual disconnect requested from UI',
      category: 'ble.connection',
      level: SentryLevel.info,
    ));
    service.invoke('sync_status', {
      'isSyncing': false,
      'pending': 0,
    });
    patientBandRemovalTimer?.cancel();

    // Send single lightweight disconnect ping so backend knows band is offline
    try {
      final profile = await BackgroundPreferences.getProfile();
      final device = await BackgroundPreferences.getDevice();
      if (profile != null && device != null) {
        final store = AuthTokenStore();
        final repo = AuthRepository(
            baseUrl: 'https://vitalvue-api.genesysailabs.com', store: store);
        final interceptor =
            AuthInterceptor(store: store, repository: repo, onLogout: () {});
        final api = BandVitalsApi(
          baseUrl: 'https://vitalvue-api.genesysailabs.com',
          authInterceptor: interceptor,
        );
        final currState = session?.currentState ?? const BandState();
        await api.ingest(
          patientId: profile.id,
          deviceId: device['id'] ?? 'gband-dev-01',
          hr: currState.hr,
          spo2: currState.spo2,
          respirationRate: currState.respiratoryRate,
          tempC: currState.tempC,
          tempSkin: currState.tempSkin,
          bpSys: currState.systolic ?? 0,
          bpDia: currState.diastolic ?? 0,
          hrv: currState.hrv ?? 0,
          stress: (currState.stress ?? 0).toString(),
          steps: currState.steps,
          calories: currState.calories,
          distanceKm: currState.distanceKm,
          battery: currState.battery,
          phoneBattery: -1,
          isConnected: false,
          isRemoved: currState.isRemoved,
        );
      }
    } catch (_) {}

    await session?.disconnect();
  });

  final patientTts = FlutterTts();
  patientTts.setVolume(1.0);
  patientTts.setSpeechRate(0.5);

  service.on('connectDevice').listen((event) async {
    if (event == null) return;
    isManualDisconnect = false;
    wasRemoved = false;
    patientBandRemovalTimer?.cancel();

    final remoteIdStr = event['remote_id'] as String;
    final deviceId = event['device_id'] as String;

    Sentry.configureScope((scope) {
      scope.setTag('device_id', deviceId);
      scope.setTag('remote_id', remoteIdStr);
    });
    Sentry.addBreadcrumb(Breadcrumb(
      message: 'connectDevice requested for $deviceId ($remoteIdStr)',
      category: 'ble.connection',
      data: {'device_id': deviceId, 'remote_id': remoteIdStr},
      level: SentryLevel.info,
    ));

    await BackgroundPreferences.saveDevice(deviceId, remoteIdStr, deviceId);
    await session?.disconnect();

    final profile = await BackgroundPreferences.getProfile();
    if (profile == null) return;

    Sentry.configureScope((scope) {
      scope.setUser(SentryUser(id: profile.id.toString(), username: profile.fullName));
      scope.setTag('patient_id', profile.id.toString());
      scope.setTag('role', 'patient');
    });

    // Register device ID on the patient's record in the backend
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
          Sentry.addBreadcrumb(Breadcrumb(
            message: 'Device $deviceId successfully registered to patient in backend',
            category: 'cloud.device',
            level: SentryLevel.info,
            data: {'device_id': deviceId, 'patient_id': profile.id},
          ));
        } else {
          Sentry.addBreadcrumb(Breadcrumb(
            message: 'Device registration returned non-success for $deviceId',
            category: 'cloud.device',
            level: SentryLevel.warning,
            data: {'device_id': deviceId, 'patient_id': profile.id},
          ));
        }
      }).catchError((e, stackTrace) {
        debugPrint('[Background] Error calling changeDevice: $e');
        Sentry.captureException(e, stackTrace: stackTrace, withScope: (scope) {
          scope.setTag('action', 'change_device');
          scope.setTag('device_id', deviceId);
        });
      });
    } catch (_) {}

    bool isSyncing = false;
    int consecutiveIngestFailures = 0;

    Future<void> syncPendingVitals({
      required BandVitalsApi api,
      required VitalsDatabase db,
      required int patientId,
      required String deviceId,
      required int battery,
      required bool isConnected,
      required bool isRemoved,
      bool isHistorySync = false,
    }) async {
      if (isManualDisconnect) {
        debugPrint('[Background] Manual disconnect active, skipping bulk sync.');
        return;
      }
      if (isSyncing) {
        debugPrint('[Background] syncPendingVitals already in progress, skipping overlapping run.');
        return;
      }
      isSyncing = true;
      bool broadcastedSync = false;
      try {
        final initialPending = await db.getUningestedCount();
        if (initialPending == 0) return;

        Sentry.addBreadcrumb(Breadcrumb(
          message: 'Starting bulk sync: $initialPending pending records (historySync=$isHistorySync)',
          category: 'sync.bulk',
          data: {
            'pending_count': initialPending,
            'is_history_sync': isHistorySync,
            'device_id': deviceId,
            'patient_id': patientId,
          },
          level: SentryLevel.info,
        ));

        if ((isHistorySync || initialPending > 1) && !isManualDisconnect) {
          broadcastedSync = true;
          service.invoke('sync_status', {
            'isSyncing': true,
            'pending': initialPending,
          });
        }

        int totalBatches = 0;
        int totalIngested = 0;

        while (true) {
          if (isManualDisconnect) {
            debugPrint('[Background] Manual disconnect active, aborting bulk sync passes.');
            Sentry.addBreadcrumb(Breadcrumb(
              message: 'Bulk sync aborted early due to manual disconnect',
              category: 'sync.bulk',
              level: SentryLevel.info,
            ));
            break;
          }

          final uningested = await db.getUningestedVitals(limit: 100);
          if (uningested.isEmpty) break;

          debugPrint('[Background] Found ${uningested.length} uningested vital records to sync');

          final ids = <int>[];
          final payloads = <Map<String, dynamic>>[];

          for (final row in uningested) {
            final id = row['_id'] as int?;
            if (id != null) ids.add(id);

            final ts = row['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;
            final recordedAt = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true);

            payloads.add(BandVitalsApi.buildVitalPayload(
              patientId: row['patient_id'] as int? ?? patientId,
              deviceId: (row['device_id'] as String?)?.isNotEmpty == true
                  ? row['device_id'] as String
                  : deviceId,
              hr: (row['hr'] as int?) ?? 0,
              spo2: (row['spo2'] as int?) ?? 0,
              respirationRate: (row['respirationRate'] as int?) ?? 0,
              tempC: (row['tempC'] as num?)?.toDouble() ?? 0.0,
              tempSkin: (row['tempSkin'] as num?)?.toDouble() ?? 0.0,
              bpSys: (row['bpSys'] as int?) ?? 0,
              bpDia: (row['bpDia'] as int?) ?? 0,
              hrv: (row['hrv'] as int?) ?? 0,
              stress: (row['stress'] ?? '0').toString(),
              steps: (row['steps'] as int?) ?? 0,
              calories: (row['calories'] as num?)?.toDouble() ?? 0.0,
              distanceKm: (row['distanceKm'] as num?)?.toDouble() ?? 0.0,
              battery: (row['battery'] as int?) ?? battery,
              phoneBattery: -1,
              isConnected: isConnected,
              isRemoved: (row['isRemoved'] == 1) || isRemoved,
              recordedAt: recordedAt,
            ));
          }

          int syncedCount = 0;
          final success = await api.bulkIngest(
            payloads,
            batchSize: 25,
            onBatchSuccess: (startIndex, endIndex) async {
              final batchIds = ids.sublist(startIndex, endIndex);
              await db.markMultipleAsIngested(batchIds);
              syncedCount += batchIds.length;
              totalIngested += batchIds.length;
              totalBatches++;
              if (broadcastedSync && !isManualDisconnect) {
                final remaining = await db.getUningestedCount();
                service.invoke('sync_status', {
                  'isSyncing': true,
                  'pending': remaining,
                });
              }
              debugPrint('[Background] ✓ Immediately marked ${batchIds.length} vitals as ingested (progress: $syncedCount/${ids.length})');
            },
          );

          if (success) {
            consecutiveIngestFailures = 0;
            debugPrint('[Background] ✓ Synced & marked $syncedCount vitals as ingested');
          } else {
            consecutiveIngestFailures++;
            debugPrint('[Background] ✗ Bulk sync interrupted ($syncedCount/${payloads.length} succeeded, remainder will retry)');
            Sentry.addBreadcrumb(Breadcrumb(
              message: 'Bulk sync batch failed (consecutive failures: $consecutiveIngestFailures)',
              category: 'sync.bulk',
              level: SentryLevel.warning,
              data: {
                'consecutive_failures': consecutiveIngestFailures,
                'synced_in_pass': syncedCount,
                'attempted_pass_size': payloads.length,
              },
            ));
            if (consecutiveIngestFailures == 3) {
              Sentry.captureMessage(
                'Cloud Ingestion Failing: 3 consecutive bulk-ingest failures for device $deviceId',
                level: SentryLevel.warning,
                withScope: (scope) {
                  scope.setTag('issue_type', 'bulk_ingest_failure');
                  scope.setTag('device_id', deviceId);
                  scope.setTag('patient_id', patientId.toString());
                  scope.setContexts('BulkIngest', {
                    'attempted_pass_size': payloads.length,
                    'synced_in_pass': syncedCount,
                  });
                },
              );
            }
            break;
          }
        }

        if (totalIngested > 0) {
          Sentry.addBreadcrumb(Breadcrumb(
            message: 'Bulk sync completed: successfully ingested $totalIngested vitals in $totalBatches batches',
            category: 'sync.bulk',
            level: SentryLevel.info,
            data: {
              'total_ingested': totalIngested,
              'total_batches': totalBatches,
              'device_id': deviceId,
            },
          ));
        }

        await db.deleteOldVitals();
      } catch (e, stackTrace) {
        debugPrint('[Background] Error during syncPendingVitals: $e');
        Sentry.captureException(e, stackTrace: stackTrace, withScope: (scope) {
          scope.setTag('task', 'sync_pending_vitals');
          scope.setTag('device_id', deviceId);
        });
      } finally {
        isSyncing = false;
        if (broadcastedSync || isManualDisconnect) {
          service.invoke('sync_status', {
            'isSyncing': false,
            'pending': 0,
          });
        }
      }
    }

    final profileConfig = VitalVueProfileConfig.current;

    session = BandSessionService(
      patientId: profile.id,
      deviceId: deviceId,
      profileConfig: profileConfig,
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

        // On manual disconnect or disconnected state, only send a lightweight single disconnect ping.
        // Do NOT insert uningested records into SQLite and do NOT drain historical backlog.
        if (isManualDisconnect || state.connectionStatus == BleConnectionStatus.disconnected) {
          debugPrint('[Background] Band disconnected (manual=$isManualDisconnect). Sending single disconnect status to cloud.');
          try {
            final ok = await api.ingest(
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
              phoneBattery: -1,
              isConnected: false,
              isRemoved: state.isRemoved,
            );
            Sentry.addBreadcrumb(Breadcrumb(
              message: 'Disconnect ingest sent: success=$ok',
              category: 'cloud.ingest',
              data: {'is_manual': isManualDisconnect, 'success': ok},
              level: ok ? SentryLevel.info : SentryLevel.warning,
            ));
          } catch (e, stackTrace) {
            debugPrint('[Background] Failed to send disconnect ingest: $e');
            Sentry.captureException(e, stackTrace: stackTrace, withScope: (scope) {
              scope.setTag('action', 'disconnect_ingest');
              scope.setTag('device_id', deviceId);
            });
          }
          return;
        }

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

        await db.insertVital(vitalData);

        await syncPendingVitals(
          api: api,
          db: db,
          patientId: profile.id,
          deviceId: deviceId,
          battery: state.battery,
          isConnected: state.connectionStatus == BleConnectionStatus.connected,
          isRemoved: state.isRemoved,
        );
      },
      onHistoryRecords: (records) async {
        final db = VitalsDatabase.instance;
        debugPrint('[Background] Processing ${records.length} historical records from band...');
        int deduplicatedCount = 0;
        int queuedCount = 0;

        for (final rec in records) {
          final hr = rec['hr'] as int? ?? 0;
          final sys = rec['bpSys'] as int? ?? 0;
          final dia = rec['bpDia'] as int? ?? 0;
          final tempC = (rec['tempC'] as num?)?.toDouble() ?? 0.0;
          final tempSkin = (rec['tempSkin'] as num?)?.toDouble() ?? 0.0;
          final steps = rec['steps'] as int? ?? 0;
          final calories = (rec['calories'] as num?)?.toDouble() ?? 0.0;
          final distanceKm = (rec['distanceKm'] as num?)?.toDouble() ?? 0.0;
          final stress = (rec['stress'] ?? 0).toString();
          final spo2 = rec['spo2'] as int? ?? 0;
          final rr = rec['respirationRate'] as int? ?? 0;
          final ts = rec['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

          // Guard against empty readings
          if (hr == 0 && sys == 0 && tempC == 0.0 && steps == 0) continue;

          // Check if this time window was already ingested live during active connection
          final alreadyIngested = await db.hasIngestedVitalNear(
            deviceId: deviceId,
            timestamp: ts,
            windowMs: 150000, // ±2.5 min window
          );

          if (alreadyIngested) {
            deduplicatedCount++;
          } else {
            queuedCount++;
          }

          await db.upsertVital({
            'timestamp': ts,
            'patient_id': profile.id,
            'device_id': deviceId,
            'hr': hr,
            'spo2': spo2,
            'respirationRate': rr,
            'tempC': tempC,
            'tempSkin': tempSkin,
            'bpSys': sys,
            'bpDia': dia,
            'hrv': rec['hrv'] as int? ?? 0,
            'stress': stress,
            'steps': steps,
            'calories': calories,
            'distanceKm': distanceKm,
            'battery': -1,
            'isRemoved': false,
            'isIngested': alreadyIngested ? 1 : 0,
          });
        }

        Sentry.addBreadcrumb(Breadcrumb(
          message: 'History records processed: $queuedCount queued, $deduplicatedCount deduplicated',
          category: 'sync.history',
          data: {
            'queued_count': queuedCount,
            'deduplicated_count': deduplicatedCount,
            'total_records': records.length,
            'device_id': deviceId,
          },
          level: SentryLevel.info,
        ));

        debugPrint('[Background] 📦 History sync: $queuedCount records queued for bulk ingest, $deduplicatedCount already covered by live ingest');
      },
      onHistoryComplete: () async {
        if (isManualDisconnect) {
          debugPrint('[Background] Manual disconnect active, skipping onHistoryComplete bulk sync.');
          return;
        }
        debugPrint('[Background] 🏁 Flushing on-band historical vitals via bulk-ingest...');
        final store = AuthTokenStore();
        final repo = AuthRepository(
            baseUrl: 'https://vitalvue-api.genesysailabs.com', store: store);
        final interceptor =
            AuthInterceptor(store: store, repository: repo, onLogout: () {});
        final api = BandVitalsApi(
          baseUrl: 'https://vitalvue-api.genesysailabs.com',
          authInterceptor: interceptor,
        );
        final currentState = session?.currentState ?? const BandState();
        await syncPendingVitals(
          api: api,
          db: VitalsDatabase.instance,
          patientId: profile.id,
          deviceId: deviceId,
          battery: currentState.battery,
          isConnected: currentState.connectionStatus == BleConnectionStatus.connected,
          isRemoved: currentState.isRemoved,
          isHistorySync: true,
        );
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

        // 24/7 Consistency fields
        'consistencyScore': state.consistencyScore,
        'cycleCount': state.cycleCount,
        'activePhase': state.activePhase,
        'vitalGapWarning': state.vitalGapWarning,

        // Clinical Architecture & Personal Baseline fields
        'news2Score': state.news2Score,
        'personalBaselineScore': state.personalBaselineScore,
        'trendStatus': state.trendStatus,
        'isRrValidated': state.isRrValidated,
        'rrConfidence': state.rrConfidence,
        'rrSource': state.rrSource,
        'parameterFreshness': state.parameterFreshness,
        'clinicalSummary': state.clinicalSummary,

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
          final cycleInfo = state.cycleCount > 0 ? ' (Cycle #${state.cycleCount})' : '';
          flutterLocalNotificationsPlugin.show(
            id: 888,
            title: 'GBand Connected',
            body:
                'HR: ${state.hr} | SpO2: ${state.spo2}% | 24/7: ${state.consistencyScore.toStringAsFixed(0)}%$cycleInfo',
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

        // Flush any uningested vitals history accumulated while offline/disconnected
        await syncPendingVitals(
          api: api,
          db: VitalsDatabase.instance,
          patientId: profile.id,
          deviceId: deviceId,
          battery: session?.currentState.battery ?? -1,
          isConnected: true,
          isRemoved: session?.currentState.isRemoved ?? false,
        );
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
