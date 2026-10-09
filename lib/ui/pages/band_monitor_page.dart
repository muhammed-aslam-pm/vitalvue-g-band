
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';


import '../../auth/user_profile.dart';
import '../../bloc/auth_bloc.dart';
import '../../bloc/auth_state.dart';
import '../../bloc/band_monitor_bloc.dart';
import '../../bloc/band_monitor_event.dart';
import '../../bloc/band_monitor_state.dart';
import '../../protocol/veepoo_protocol.dart';
import '../widgets/device_scan_sheet.dart';
import '../widgets/vital_card.dart';
import 'ecg_measurement_page.dart';
import 'profile_page.dart';
import 'vitals_details_page.dart';
import '../theme/app_theme.dart';

class BandMonitorPage extends StatefulWidget {
  const BandMonitorPage({super.key});

  @override
  State<BandMonitorPage> createState() => _BandMonitorPageState();
}

class _BandMonitorPageState extends State<BandMonitorPage>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    Permission.notification.request();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissionsAndScan(BuildContext context) async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.locationWhenInUse,
      Permission.ignoreBatteryOptimizations,
      Permission.notification,
    ].request();

    if (!context.mounted) return;

    // Check if Location Services (GPS) is enabled (mandatory on Android 6-11 for BLE scanning)
    try {
      final locStatus = await Permission.location.serviceStatus;
      if (locStatus == ServiceStatus.disabled && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Notice: Location Services (GPS) are OFF. Please enable Location in phone settings if scanning finds no devices.',
            ),
            backgroundColor: AppColors.amber,
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (_) {}

    if (!context.mounted) return;

    context.read<BandMonitorBloc>().add(const StartScan());

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BlocProvider.value(
        value: context.read<BandMonitorBloc>(),
        child: const DeviceScanSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          // Background gradient blobs
          _BackgroundGradient(),

          // Main content
          SafeArea(
            child: BlocConsumer<BandMonitorBloc, BandMonitorState>(
              listener: (context, state) {
                if (state is BandDisconnectedState && state.reason != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(state.reason!),
                      backgroundColor: AppColors.red,
                    ),
                  );
                }
              },
              builder: (context, bandState) {
                // Fetch profile for the app bar profile button
                return BlocBuilder<AuthBloc, AuthState>(
                  buildWhen: (p, n) => n is AuthAuthenticated,
                  builder: (context, authState) {
                    final profile = authState is AuthAuthenticated
                        ? authState.profile
                        : null;
                    return CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: _buildAppBar(context, bandState, profile),
                        ),
                        SliverToBoxAdapter(
                          child: _SyncStatusBanner(
                            isSyncing: bandState.isSyncing,
                            pendingCount: bandState.syncRemaining,
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: _buildConnectionBanner(context, bandState),
                        ),
                        SliverPadding(
                          padding:
                              const EdgeInsets.fromLTRB(20, 0, 20, 20),
                          sliver: _buildBody(context, bandState),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: BlocBuilder<BandMonitorBloc, BandMonitorState>(
        builder: (context, state) {
          if (state is BandConnectedState) {
            return FloatingActionButton.extended(
              onPressed: () =>
                  context.read<BandMonitorBloc>().add(const DisconnectBand()),
              backgroundColor: Theme.of(context).colorScheme.surface,
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              icon: const Icon(Icons.bluetooth_disabled_rounded),
              label: const Text('Disconnect'),
            );
          }
          return FloatingActionButton.extended(
            onPressed: () => _requestPermissionsAndScan(context),
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.bluetooth_searching_rounded),
            label: const Text('Scan for Band'),
          );
        },
      ),
    );
  }

  // ── App Bar ───────────────────────────────────────────────────────────────

  Widget _buildAppBar(
      BuildContext context, BandMonitorState state, UserProfile? profile) {
    final isPatient = profile?.isPatient ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'VitalVue',
                  style: GoogleFonts.inter(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  isPatient ? 'JStyle JCV5' : (profile?.role ?? ''),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Battery & connection chips
          if (state is BandConnectedState) ...[
            _WearingChip(isRemoved: state.vitals.isRemoved),
            _BatteryChip(battery: state.vitals.battery),
            const SizedBox(width: 8),
          ],
          _ConnectionChip(state: state),
          const SizedBox(width: 8),
          // Profile button — always visible
          if (profile != null)
            IconButton(
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ProfilePage(profile: profile),
                ));
              },
              icon: Icon(Icons.person_rounded, color: Theme.of(context).colorScheme.onSurface),
              tooltip: 'Profile',
            ),
        ],
      ),
    );
  }

  // ── Connection status banner ───────────────────────────────────────────────

  Widget _buildConnectionBanner(BuildContext context, BandMonitorState state) {
    // Off-wrist alert — shown on top of everything when band is removed
    if (state is BandConnectedState && state.vitals.isRemoved) {
      return _OffWristBanner(pulseController: _pulseController);
    }

    if (state is BandConnectingState) {
      return const _InfoBanner(
        color: AppColors.amber,
        icon: Icons.bluetooth_searching_rounded,
        message: 'Connecting to band…',
      );
    }

    if (state is BandDisconnectedState) {
      return const _InfoBanner(
        color: AppColors.red,
        icon: Icons.bluetooth_disabled_rounded,
        message: 'Not connected — tap Scan to find your band.',
      );
    }

    return const SizedBox.shrink();
  }

  // ── Body ──────────────────────────────────────────────────────────────────

  Widget _buildBody(BuildContext context, BandMonitorState state) {
    if (state is BandConnectedState) {
      return _buildVitalsGrid(state.vitals);
    }

    if (state is BandScanningState || state is BandConnectingState) {
      return SliverFillRemaining(
        child: _buildLoadingState(state),
      );
    }

    return SliverFillRemaining(
      child: _buildIdleState(),
    );
  }


  Widget _buildVitalsGrid(BandState v) {
    final bpText = (v.systolic != null && v.diastolic != null)
        ? '${v.systolic}/${v.diastolic}'
        : '--/--';

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.95,
      ),
      delegate: SliverChildListDelegate([
        VitalCard(
          label: 'Heart Rate',
          value: v.hr > 0 ? '${v.hr}' : '--',
          unit: 'bpm',
          icon: Icons.favorite_rounded,
          accentColor: AppColors.red,
          subtitle: 'Live',
          isAlert: false,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'Heart Rate',
              dbColumnName: 'hr',
              unit: 'bpm',
              accentColor: AppColors.red,
            ),
          )),
        ),
        VitalCard(
          label: 'ECG',
          value: v.lastEcgResult != null && v.lastEcgResult!.aveHeart > 0
              ? '${v.lastEcgResult!.aveHeart}'
              : 'Measure',
          unit: v.lastEcgResult != null && v.lastEcgResult!.aveHeart > 0 ? 'bpm' : '',
          icon: Icons.electric_bolt_rounded,
          accentColor: AppColors.green,
          subtitle: v.lastEcgResult != null
              ? 'HRV: ${v.lastEcgResult!.aveHrv} ms | QT: ${v.lastEcgResult!.aveQt} ms'
              : 'Cardiac Rhythm Assessment',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => BlocProvider.value(
              value: context.read<BandMonitorBloc>(),
              child: const EcgMeasurementPage(),
            ),
          )),
        ),
        VitalCard(
          label: 'SpO₂',
          value: v.spo2 > 0 ? '${v.spo2}' : '--',
          unit: '%',
          icon: Icons.water_drop_rounded,
          accentColor: AppColors.cyan,
          subtitle: 'Oxygen saturation',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'SpO₂',
              dbColumnName: 'spo2',
              unit: '%',
              accentColor: AppColors.cyan,
            ),
          )),
        ),
        VitalCard(
          label: 'Respiration',
          value: v.respiratoryRate > 0 ? '${v.respiratoryRate}' : '--',
          unit: 'rpm',
          icon: Icons.air_rounded,
          accentColor: AppColors.cyan,
          subtitle: 'Breaths per minute',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'Respiratory Rate',
              dbColumnName: 'respirationRate',
              unit: 'rpm',
              accentColor: AppColors.cyan,
            ),
          )),
        ),
        VitalCard(
          label: 'Temperature',
          value: v.tempC > 0 ? '${v.tempC.toStringAsFixed(1)}°' : '--',
          unit: 'C',
          icon: Icons.thermostat_rounded,
          accentColor: AppColors.purple,
          subtitle: v.tempSkin > 0
              ? 'Core: ${v.tempC > 0 ? v.tempC.toStringAsFixed(1) : "--"}° | Skin: ${v.tempSkin.toStringAsFixed(1)}°'
              : 'Body & Skin Temp',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'Body Temp',
              dbColumnName: 'tempC',
              unit: '°C',
              accentColor: AppColors.purple,
            ),
          )),
        ),
        VitalCard(
          label: 'Blood Pressure',
          value: bpText,
          unit: 'mmHg',
          icon: Icons.monitor_heart_rounded,
          accentColor: AppColors.amber,
          subtitle: 'Systolic / Diastolic',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'Blood Pressure (Systolic)',
              dbColumnName: 'bpSys',
              unit: 'mmHg',
              accentColor: AppColors.amber,
            ),
          )),
        ),
        VitalCard(
          label: 'HRV',
          value: (v.hrv != null && v.hrv! > 0) ? '${v.hrv}' : '--',
          unit: 'ms',
          icon: Icons.favorite_border_rounded,
          accentColor: AppColors.purple,
          subtitle: 'Heart Rate Variability',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'HRV',
              dbColumnName: 'hrv',
              unit: 'ms',
              accentColor: AppColors.purple,
            ),
          )),
        ),
        VitalCard(
          label: 'Stress',
          value: (v.stress != null && v.stress! > 0) ? '${v.stress}' : '--',
          unit: '',
          icon: Icons.psychology_rounded,
          accentColor: AppColors.amber,
          subtitle: 'Stress Level',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'Stress Level',
              dbColumnName: 'stress',
              unit: '',
              accentColor: AppColors.amber,
            ),
          )),
        ),
        VitalCard(
          label: 'Steps',
          value: v.steps > 0 ? '${v.steps}' : '--',
          unit: 'steps',
          icon: Icons.directions_walk_rounded,
          accentColor: AppColors.green,
          subtitle: 'Daily Activity',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'Steps',
              dbColumnName: 'steps',
              unit: 'steps',
              accentColor: AppColors.green,
            ),
          )),
        ),
        VitalCard(
          label: 'Distance',
          value: v.distanceKm > 0 ? v.distanceKm.toStringAsFixed(2) : '--',
          unit: 'km',
          icon: Icons.route_rounded,
          accentColor: AppColors.primary,
          subtitle: 'Estimated',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'Distance',
              dbColumnName: 'distanceKm',
              unit: 'km',
              accentColor: AppColors.primary,
            ),
          )),
        ),
        VitalCard(
          label: 'Calories',
          value: v.calories > 0 ? v.calories.toStringAsFixed(0) : '--',
          unit: 'kcal',
          icon: Icons.local_fire_department_rounded,
          accentColor: AppColors.amber,
          subtitle: 'Burned today',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VitalsDetailsPage(
              title: 'Calories',
              dbColumnName: 'calories',
              unit: 'kcal',
              accentColor: AppColors.amber,
            ),
          )),
        ),
        VitalCard(
          label: 'Sleep',
          value: v.totalSleepMinutes > 0
              ? '${v.totalSleepMinutes ~/ 60}h ${v.totalSleepMinutes % 60}m'
              : '--',
          unit: '',
          icon: Icons.bedtime_rounded,
          accentColor: const Color(0xFF5C6BC0),
          subtitle: v.totalSleepMinutes > 0
              ? 'Deep: ${v.deepSleepMinutes}m | Light: ${v.lightSleepMinutes}m'
              : 'Sleep Tracking',
        ),
      ]),
    );
  }

  Widget _buildLoadingState(BandMonitorState state) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
            color: Color(0xFF1A73E8),
            strokeWidth: 2.5,
          ),
          const SizedBox(height: 24),
          Text(
            state is BandConnectingState
                ? 'Connecting…\nSending init sequence to band'
                : 'Scanning for JStyle devices…',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              fontSize: 15,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdleState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.watch_rounded,
            size: 72,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2),
          )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .scale(
                  begin: const Offset(0.95, 0.95),
                  end: const Offset(1.05, 1.05),
                  duration: 2000.ms,
                  curve: Curves.easeInOut),
          const SizedBox(height: 24),
          Text(
            'No Band Connected',
            style: GoogleFonts.inter(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap the button below to scan\nfor your JStyle JCV5 band.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              fontSize: 14,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 48),
          // Battery & status row placeholder
        ],
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _BackgroundGradient extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: -100,
          left: -80,
          child: _blob(AppColors.primary.withValues(alpha: 0.15), 300),
        ),
        Positioned(
          bottom: 100,
          right: -60,
          child: _blob(AppColors.cyan.withValues(alpha: 0.10), 260),
        ),
        Positioned(
          top: 300,
          left: 80,
          child: _blob(AppColors.purple.withValues(alpha: 0.08), 200),
        ),
      ],
    );
  }

  Widget _blob(Color color, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color,
              color.withValues(alpha: 0.0),
            ],
          ),
        ),
      );
}

// ignore: unused_element
class _WearingChip extends StatelessWidget {
  const _WearingChip({required this.isRemoved});
  final bool isRemoved;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = isRemoved
        ? ('Off-Wrist', AppColors.red, Icons.watch_off_rounded)
        : ('On-Wrist', AppColors.cyan, Icons.watch_rounded);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _BatteryChip extends StatelessWidget {
  const _BatteryChip({required this.battery});
  final int battery;

  @override
  Widget build(BuildContext context) {
    Color color;
    IconData icon;
    if (battery > 50) {
      color = AppColors.green;
      icon = Icons.battery_full_rounded;
    } else if (battery > 20) {
      color = AppColors.amber;
      icon = Icons.battery_5_bar_rounded;
    } else if (battery >= 0) {
      color = AppColors.red;
      icon = Icons.battery_alert_rounded;
    } else {
      color = AppColors.textMuted;
      icon = Icons.battery_unknown_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(
            battery >= 0 ? '$battery%' : '--',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.state});
  final BandMonitorState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      BandConnectedState() => ('Connected', AppColors.green),
      BandConnectingState() => ('Connecting', AppColors.amber),
      BandScanningState() => ('Scanning', AppColors.primary),
      _ => ('Disconnected', AppColors.textMuted),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          )
              .animate(onPlay: (c) => c.repeat())
              .scale(
                  begin: const Offset(0.8, 0.8),
                  end: const Offset(1.2, 1.2),
                  duration: 800.ms,
                  curve: Curves.easeInOut),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _OffWristBanner extends StatelessWidget {
  const _OffWristBanner({required this.pulseController});
  final AnimationController pulseController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseController,
      builder: (context, _) {
        return Container(
          margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Color.lerp(
              const Color(0xFFE53935).withValues(alpha: 0.18),
              const Color(0xFFE53935).withValues(alpha: 0.32),
              pulseController.value,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Color.lerp(
                const Color(0xFFE53935).withValues(alpha: 0.4),
                const Color(0xFFE53935).withValues(alpha: 0.8),
                pulseController.value,
              )!,
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Color(0xFFFF6B6B), size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Band Off-Wrist',
                      style: TextStyle(
                        color: Color(0xFFFF6B6B),
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      'No heart rate signal for >100 seconds. Please reapply sensor.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.color,
    required this.icon,
    required this.message,
  });
  final Color color;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8), fontSize: 13),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.1, end: 0);
  }
}


// ── Animated Sync Status Banner ─────────────────────────────────────────────

class _SyncStatusBanner extends StatefulWidget {
  final bool isSyncing;
  final int pendingCount;

  const _SyncStatusBanner({
    required this.isSyncing,
    required this.pendingCount,
  });

  @override
  State<_SyncStatusBanner> createState() => _SyncStatusBannerState();
}

class _SyncStatusBannerState extends State<_SyncStatusBanner> {
  bool _showCompleted = false;

  @override
  void didUpdateWidget(covariant _SyncStatusBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When syncing transitions from true to false, show brief 'Synced' state before collapsing
    if (oldWidget.isSyncing && !widget.isSyncing && oldWidget.pendingCount > 0) {
      setState(() {
        _showCompleted = true;
      });
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) {
          setState(() {
            _showCompleted = false;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVisible = widget.isSyncing || _showCompleted;

    return AnimatedSize(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
      child: isVisible
          ? Container(
              margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _showCompleted
                    ? AppColors.green.withValues(alpha: 0.15)
                    : AppColors.cyan.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _showCompleted
                      ? AppColors.green.withValues(alpha: 0.4)
                      : AppColors.cyan.withValues(alpha: 0.35),
                  width: 1.2,
                ),
              ),
              child: Row(
                children: [
                  if (_showCompleted)
                    const Icon(
                      Icons.check_circle_rounded,
                      color: AppColors.green,
                      size: 20,
                    )
                  else
                    const Icon(
                      Icons.sync_rounded,
                      color: AppColors.cyan,
                      size: 20,
                    )
                        .animate(onPlay: (controller) => controller.repeat())
                        .rotate(duration: 1600.ms),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _showCompleted
                              ? 'Backlog Vitals Synced'
                              : 'Syncing Vitals to Cloud',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _showCompleted
                                ? AppColors.green
                                : AppColors.cyan,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _showCompleted
                              ? 'All historical records uploaded successfully'
                              : (widget.pendingCount > 0
                                  ? '${widget.pendingCount} records queued for cloud ingest…'
                                  : 'Uploading historical readings…'),
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!_showCompleted)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.cyan.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: AppColors.cyan,
                              shape: BoxShape.circle,
                            ),
                          )
                              .animate(
                                  onPlay: (controller) => controller.repeat(reverse: true))
                              .scale(begin: const Offset(0.7, 0.7), end: const Offset(1.3, 1.3)),
                          const SizedBox(width: 5),
                          Text(
                            'SYNCING',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.cyan,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
