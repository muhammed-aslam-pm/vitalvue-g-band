import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'auth/auth_interceptor.dart';
import 'auth/auth_repository.dart';
import 'auth/auth_token_store.dart';
import 'bloc/auth_bloc.dart';
import 'bloc/auth_event.dart';
import 'bloc/auth_state.dart';
import 'bloc/patients_bloc.dart';
import 'bloc/patients_event.dart';
import 'cloud/patients_repository.dart';
import 'cloud/vitals_sse_service.dart';
import 'ui/pages/login_page.dart';
import 'ui/pages/staff_dashboard_page.dart';
import 'ui/pages/band_monitor_page.dart';
import 'background/background_service.dart';
import 'bloc/band_monitor_bloc.dart';
import 'bloc/band_monitor_event.dart';
import 'cloud/band_vitals_api.dart';
import 'package:veepoo_sdk/veepoo_sdk.dart';
import 'protocol/veepoo_protocol.dart';
import 'ui/theme/app_theme.dart';

// ── Configuration — edit these or pass via --dart-define ─────────────────────
const _kDefaultSentryDsn =
    'https://dd4d1111c317b961e3f1f6e80430ea9a@o4512067849945088.ingest.us.sentry.io/4512067856105472';
const _kApiBaseUrl = String.fromEnvironment(
  'BAND_API_URL',
  defaultValue: 'https://vitalvue-api.genesysailabs.com',
);
const _kPatientId = int.fromEnvironment('PATIENT_ID', defaultValue: 118);
const _kDeviceId = String.fromEnvironment('DEVICE_ID', defaultValue: 'gband-dev-01');
const _kPersonalInfo = PersonalInfo(
  sex: 1,
  age: 30,
  heightCm: 175,
  weightKg: 70,
  stepLengthCm: 70,
);

// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  SentryWidgetsFlutterBinding.ensureInitialized();
  await initializeBackgroundService();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: AppColors.background,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  VeepooSdk.onError = (error, stack, {action, context}) {
    Sentry.captureException(
      error,
      stackTrace: stack,
      withScope: (scope) {
        scope.setTag('isolate', 'main');
        if (action != null) scope.setTag('action', action);
        if (context != null) scope.setContexts('veepoo', context);
      },
    );
  };

  await SentryFlutter.init(
    (options) {
      options.dsn = const String.fromEnvironment('SENTRY_DSN', defaultValue: _kDefaultSentryDsn);
      options.tracesSampleRate = 1.0; // 100% sample rate during development & initial setup
      options.sendDefaultPii = true;
    },
    appRunner: () async {
      runApp(
        const GBandMonitorApp(),
      );
    },
  );
}

class GBandMonitorApp extends StatefulWidget {
  const GBandMonitorApp({super.key});

  @override
  State<GBandMonitorApp> createState() => _GBandMonitorAppState();
}

class _GBandMonitorAppState extends State<GBandMonitorApp> {
  // ── Singletons created once ───────────────────────────────────────────────
  late final AuthTokenStore _tokenStore;
  late final AuthRepository _authRepo;
  late final AuthBloc _authBloc;
  late final AuthInterceptor _authInterceptor;
  late final VitalsSseService _sseService;
  late final PatientsRepository _patientsRepo;
  late final PatientsBloc _patientsBloc;
  late final BandVitalsApi _vitalsApi;
  late final BandMonitorBloc _bandBloc;

  @override
  void initState() {
    super.initState();
    _tokenStore = AuthTokenStore();
    _authRepo = AuthRepository(baseUrl: _kApiBaseUrl, store: _tokenStore);

    _authBloc = AuthBloc(repository: _authRepo, store: _tokenStore);

    _authInterceptor = AuthInterceptor(
      store: _tokenStore,
      repository: _authRepo,
      // When the refresh token is also expired, force the user back to login.
      onLogout: () => _authBloc.forceLogout(),
    );

    _patientsRepo = PatientsRepository(
      baseUrl: _kApiBaseUrl,
      authInterceptor: _authInterceptor,
    );
    
    _vitalsApi = BandVitalsApi(
      baseUrl: _kApiBaseUrl,
      authInterceptor: _authInterceptor,
    );

    _bandBloc = BandMonitorBloc(
      vitalsApi: _vitalsApi,
      patientId: _kPatientId,
      deviceId: _kDeviceId,
      personalInfo: _kPersonalInfo,
    );
    _sseService = VitalsSseService(
      baseUrl: _kApiBaseUrl,
      tokenStore: _tokenStore,
    );
    _patientsBloc = PatientsBloc(
      repository: _patientsRepo,
      sseService: _sseService,
    );

    // Check for persisted token on startup.
    _authBloc.add(const AuthCheckStatus());
  }

  @override
  void dispose() {
    _authBloc.close();
    _bandBloc.close();
    _patientsBloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: _patientsRepo),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: _authBloc),
          BlocProvider.value(value: _bandBloc),
          BlocProvider.value(value: _patientsBloc),
        ],
        child: MaterialApp(
          title: 'G Band Monitor',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(),
          home: BlocConsumer<AuthBloc, AuthState>(
            listener: (context, state) {
              if (state is AuthAuthenticated) {
                final p = state.profile;
                if (p.isPatient) {
                  context.read<BandMonitorBloc>().add(UpdateBandContext(
                        patientId: p.id,
                        personalInfo: PersonalInfo(
                          sex: (p.gender ?? 'Male').toLowerCase().startsWith('m')
                              ? 1
                              : 0,
                          age: p.age ?? 30,
                          heightCm: p.height ?? 170,
                          weightKg: p.weight ?? 70,
                          stepLengthCm: ((p.height ?? 170) * 0.415).round(),
                        ),
                      ));
                }
              } else if (state is AuthUnauthenticated) {
                context.read<BandMonitorBloc>().add(const DisconnectBand());
                context.read<PatientsBloc>().add(const StopPatients());
              }
            },
            builder: (context, state) {
              if (state is AuthAuthenticated) {
                return state.profile.isPatient
                    ? const BandMonitorPage()
                    : const StaffDashboardPage();
              }
              return switch (state) {
                AuthInitial() => const _SplashScreen(),
                _ => const LoginPage(),
              };
            },
          ),
        ),
      ),
    );
  }

  ThemeData _buildTheme() {
    return AppTheme.darkTheme;
  }
}

// ── Splash shown for the <100 ms token-check ─────────────────────────────────
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: CircularProgressIndicator(
          color: AppColors.primary,
          strokeWidth: 2,
        ),
      ),
    );
  }
}
