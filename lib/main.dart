import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

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
import 'protocol/veepoo_protocol.dart';

// ── Configuration — edit these or pass via --dart-define ─────────────────────
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
  WidgetsFlutterBinding.ensureInitialized();
  await initializeBackgroundService();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));
  runApp(const GBandMonitorApp());
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
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF5F7FA),
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF1A73E8),
        secondary: Color(0xFF00BFA5),
        surface: Colors.white,
        error: Color(0xFFE53935),
      ),
      textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme),
      useMaterial3: true,
    );
  }
}

// ── Splash shown for the <100 ms token-check ─────────────────────────────────
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF5F7FA),
      body: Center(
        child: CircularProgressIndicator(
          color: Color(0xFF1A73E8),
          strokeWidth: 2,
        ),
      ),
    );
  }
}
