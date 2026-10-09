import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../bloc/band_monitor_bloc.dart';
import '../../bloc/band_monitor_event.dart';
import '../../bloc/band_monitor_state.dart';
import '../../protocol/veepoo_protocol.dart';
import '../theme/app_theme.dart';

class EcgMeasurementPage extends StatefulWidget {
  const EcgMeasurementPage({super.key});

  @override
  State<EcgMeasurementPage> createState() => _EcgMeasurementPageState();
}

enum _EcgStep { instructions, measuring, results }

class _EcgMeasurementPageState extends State<EcgMeasurementPage>
    with SingleTickerProviderStateMixin {
  _EcgStep _currentStep = _EcgStep.instructions;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _startMeasurement() {
    HapticFeedback.mediumImpact();
    setState(() {
      _currentStep = _EcgStep.measuring;
    });
    context.read<BandMonitorBloc>().add(const StartEcgMeasurement());
  }

  void _stopMeasurement() {
    HapticFeedback.selectionClick();
    context.read<BandMonitorBloc>().add(const StopEcgMeasurement());
    setState(() {
      _currentStep = _EcgStep.instructions;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () {
            if (_currentStep == _EcgStep.measuring) {
              _stopMeasurement();
            }
            Navigator.of(context).pop();
          },
        ),
        title: Text(
          'ECG Heart Monitor',
          style: GoogleFonts.plusJakartaSans(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
      ),
      body: BlocConsumer<BandMonitorBloc, BandMonitorState>(
        listener: (context, state) {
          if (state is BandConnectedState) {
            final bs = state.vitals;
            // Transition to results if measurement finished or 100% reached
            if (_currentStep == _EcgStep.measuring &&
                (bs.ecgProgress >= 100 || (!bs.isEcgMeasuring && bs.ecgProgress > 0))) {
              HapticFeedback.heavyImpact();
              setState(() {
                _currentStep = _EcgStep.results;
              });
            }
          }
        },
        builder: (context, state) {
          final bandState =
              state is BandConnectedState ? state.vitals : const BandState();

          return SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: switch (_currentStep) {
                _EcgStep.instructions => _buildInstructionsView(context, bandState),
                _EcgStep.measuring => _buildMeasuringView(context, bandState),
                _EcgStep.results => _buildResultsView(context, bandState),
              },
            ),
          );
        },
      ),
    );
  }

  // ── Step 1: Pre-test Instructions ─────────────────────────────────────────

  Widget _buildInstructionsView(BuildContext context, BandState bandState) {
    final isConnected =
        bandState.connectionStatus == BleConnectionStatus.connected;

    return SingleChildScrollView(
      key: const ValueKey('instructions_view'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Visual Banner Container
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppColors.cardBorder),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00E676).withValues(alpha: 0.08),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              children: [
                // Animated ECG pulse icon container
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final scale = 1.0 + (_pulseController.value * 0.08);
                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [Color(0xFF00E676), Color(0xFF00B0FF)],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00E676).withValues(alpha: 0.4),
                              blurRadius: 24 * _pulseController.value,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.favorite_rounded,
                          color: Colors.white,
                          size: 46,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                Text(
                  'Electrocardiogram (ECG)',
                  style: GoogleFonts.plusJakartaSans(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Records the electrical activity of your heart to evaluate rhythm and cardiac stability.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.plusJakartaSans(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),

          const SizedBox(height: 28),

          Text(
            'How to Measure Properly',
            style: GoogleFonts.plusJakartaSans(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 16),

          _buildGuidanceStepTile(
            number: '1',
            title: 'Secure Wrist Placement',
            description:
                'Ensure the smart band is worn snugly on your wrist, right above your wrist bone.',
            icon: Icons.watch_rounded,
            color: const Color(0xFF00B0FF),
          ),

          const SizedBox(height: 12),

          _buildGuidanceStepTile(
            number: '2',
            title: 'Touch the Top Electrode',
            description:
                'Place your index finger of the opposite hand firmly on the metallic electrode on the band.',
            icon: Icons.touch_app_rounded,
            color: const Color(0xFF00E676),
          ),

          const SizedBox(height: 12),

          _buildGuidanceStepTile(
            number: '3',
            title: 'Rest & Remain Still',
            description:
                'Rest your arms comfortably on a table or lap. Remain calm and refrain from speaking for 30 seconds.',
            icon: Icons.accessibility_new_rounded,
            color: const Color(0xFFFFB300),
          ),

          const SizedBox(height: 32),

          // Start Button
          ElevatedButton(
            onPressed: isConnected ? _startMeasurement : null,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 18),
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
              disabledBackgroundColor: Colors.white12,
              disabledForegroundColor: Colors.white38,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 4,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isConnected
                      ? Icons.play_arrow_rounded
                      : Icons.bluetooth_disabled_rounded,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Text(
                  isConnected
                      ? 'I\'m Ready - Start ECG'
                      : 'Connect GBand to Measure',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 200.ms),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildGuidanceStepTile({
    required String number,
    required String title,
    required String description,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.plusJakartaSans(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: GoogleFonts.plusJakartaSans(
                    color: Colors.white60,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Step 2: Active Measuring & Waveform ───────────────────────────────────

  Widget _buildMeasuringView(BuildContext context, BandState bandState) {
    final progress = bandState.ecgProgress.clamp(0, 100);
    final unpassWear = bandState.unpassWear;
    final statusMsg = bandState.ecgStatusMessage ?? 'Measuring...';
    final hr = bandState.hr;
    final hrv = bandState.hrv ?? 0;

    return SingleChildScrollView(
      key: const ValueKey('measuring_view'),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Live Feedback Status Banner
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: unpassWear
                  ? const Color(0xFFFF3D00).withValues(alpha: 0.2)
                  : const Color(0xFF00E676).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: unpassWear
                    ? const Color(0xFFFF3D00)
                    : const Color(0xFF00E676).withValues(alpha: 0.5),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: unpassWear
                      ? const Color(0xFFFF3D00).withValues(alpha: 0.2)
                      : const Color(0xFF00E676).withValues(alpha: 0.1),
                  blurRadius: 16,
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(
                  unpassWear
                      ? Icons.warning_amber_rounded
                      : Icons.sensors_rounded,
                  color: unpassWear ? const Color(0xFFFF5252) : const Color(0xFF00E676),
                  size: 28,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        unpassWear ? 'ELECTRODE TOUCH LOST' : 'ECG SIGNAL ACTIVE',
                        style: GoogleFonts.plusJakartaSans(
                          color: unpassWear ? const Color(0xFFFF5252) : const Color(0xFF00E676),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        statusMsg,
                        style: GoogleFonts.plusJakartaSans(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Real-time ECG Graph Waveform Container
          Container(
            height: 220,
            decoration: BoxDecoration(
              color: const Color(0xFF090D16),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.cardBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                children: [
                  // ECG Grid & Live Waveform Line
                  CustomPaint(
                    size: Size.infinite,
                    painter: EcgWaveformPainter(
                      adcPoints: bandState.ecgAdcPoints,
                      isTouchLost: unpassWear,
                    ),
                  ),

                  // Overlay live BPM badge
                  Positioned(
                    top: 12,
                    right: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.favorite_rounded, color: Color(0xFFFF5252), size: 16),
                          const SizedBox(width: 6),
                          Text(
                            hr > 0 ? '$hr BPM' : '-- BPM',
                            style: GoogleFonts.plusJakartaSans(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Live HRV overlay badge
                  Positioned(
                    top: 12,
                    left: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.monitor_heart_rounded, color: Color(0xFF00B0FF), size: 16),
                          const SizedBox(width: 6),
                          Text(
                            hrv > 0 ? 'HRV: $hrv ms' : 'HRV: --',
                            style: GoogleFonts.plusJakartaSans(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Progress Gauge & Percentage
          Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: CircularProgressIndicator(
                    value: progress / 100.0,
                    strokeWidth: 8,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      unpassWear
                          ? const Color(0xFFFF5252)
                          : const Color(0xFF00E676),
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$progress%',
                      style: GoogleFonts.plusJakartaSans(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'PROGRESS',
                      style: GoogleFonts.plusJakartaSans(
                        color: Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // Stop / Cancel Button
          OutlinedButton(
            onPressed: _stopMeasurement,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              side: const BorderSide(color: Colors.white30),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              'Cancel Test',
              style: GoogleFonts.plusJakartaSans(
                color: Colors.white70,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Step 3: Cardiac Results & Diagnostic Summary ──────────────────────────

  Widget _buildResultsView(BuildContext context, BandState bandState) {
    final result = bandState.lastEcgResult;
    final diag = bandState.lastEcgDiagnosis;

    final aveHr = result?.aveHeart ?? bandState.hr;
    final aveHrv = result?.aveHrv ?? bandState.hrv ?? 0;
    final aveQt = result?.aveQt ?? 0;
    final aveResp = result?.aveResRate ?? 0;
    final isSuccess = result?.isSuccess ?? true;

    return SingleChildScrollView(
      key: const ValueKey('results_view'),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Result Header Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.green.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676).withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_circle_outline_rounded,
                    color: Color(0xFF00E676),
                    size: 36,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isSuccess ? 'ECG Analysis Complete' : 'Incomplete ECG Test',
                        style: GoogleFonts.plusJakartaSans(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Sinus Rhythm Assessment Verified',
                        style: GoogleFonts.plusJakartaSans(
                          color: const Color(0xFF00E676),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(duration: 300.ms),

          const SizedBox(height: 20),

          // Primary Cardiac Metrics 2x2 Grid
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.4,
            children: [
              _buildMetricCard(
                title: 'Average HR',
                value: aveHr > 0 ? '$aveHr' : '--',
                unit: 'bpm',
                icon: Icons.favorite_rounded,
                color: const Color(0xFFFF5252),
              ),
              _buildMetricCard(
                title: 'HRV / SDNN',
                value: aveHrv > 0 ? '$aveHrv' : '--',
                unit: 'ms',
                icon: Icons.monitor_heart_rounded,
                color: const Color(0xFF00B0FF),
              ),
              _buildMetricCard(
                title: 'QT Interval',
                value: aveQt > 0 ? '$aveQt' : '--',
                unit: 'ms',
                icon: Icons.graphic_eq_rounded,
                color: const Color(0xFFFFB300),
              ),
              _buildMetricCard(
                title: 'Respiration',
                value: aveResp > 0 ? '$aveResp' : '--',
                unit: 'rpm',
                icon: Icons.air_rounded,
                color: const Color(0xFFAB47BC),
              ),
            ],
          ).animate().fadeIn(delay: 150.ms),

          const SizedBox(height: 20),

          // Diagnostic Health Summary Tile
          if (diag != null) ...[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.analytics_rounded, color: Color(0xFF00E676), size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Autonomic & Wellness Indices',
                        style: GoogleFonts.plusJakartaSans(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 24),
                  _buildDiagRow('Stress Index', '${diag.pressureIndex}', '/ 100'),
                  const SizedBox(height: 8),
                  _buildDiagRow('Fatigue Level', '${diag.fatigueIndex}', '/ 100'),
                  const SizedBox(height: 8),
                  _buildDiagRow('Vascular Assessment', diag.angioscleroticRisk == 0 ? 'Normal' : 'Attention Suggested', ''),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Medical Disclaimer
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded, color: Colors.white38, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Disclaimer: ECG measurements from GBand are intended for personal wellness reference. Consult a qualified medical practitioner for diagnosis.',
                    style: GoogleFonts.plusJakartaSans(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // Action Buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _startMeasurement,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: const BorderSide(color: Color(0xFF00E676)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    'Retest ECG',
                    style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF00E676),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    'Done',
                    style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String unit,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: GoogleFonts.plusJakartaSans(
                  color: Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(icon, color: color, size: 18),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: GoogleFonts.plusJakartaSans(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: GoogleFonts.plusJakartaSans(
                  color: Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDiagRow(String label, String val, String suffix) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            color: Colors.white70,
            fontSize: 13,
          ),
        ),
        Text(
          '$val $suffix',
          style: GoogleFonts.plusJakartaSans(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

// ── Custom Painter for Real-time ECG Waveform ───────────────────────────────

class EcgWaveformPainter extends CustomPainter {
  final List<int> adcPoints;
  final bool isTouchLost;

  EcgWaveformPainter({
    required this.adcPoints,
    required this.isTouchLost,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw Grid Lines (standard medical grid pattern)
    final gridPaint = Paint()
      ..color = const Color(0xFF00E676).withValues(alpha: 0.08)
      ..strokeWidth = 1.0;

    const gridSpacing = 20.0;
    for (double x = 0; x < size.width; x += gridSpacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += gridSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (adcPoints.isEmpty) {
      // Flat line when no data
      final flatPaint = Paint()
        ..color = isTouchLost
            ? const Color(0xFFFF5252).withValues(alpha: 0.5)
            : const Color(0xFF00E676).withValues(alpha: 0.5)
        ..strokeWidth = 2.0;
      final midY = size.height / 2;
      canvas.drawLine(Offset(0, midY), Offset(size.width, midY), flatPaint);
      return;
    }

    // 2. Draw ECG Signal Curve
    final wavePaint = Paint()
      ..color = isTouchLost ? const Color(0xFFFF5252) : const Color(0xFF00E676)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();

    // Map ADC values to height bounds
    final minAdc = adcPoints.reduce(math.min);
    final maxAdc = adcPoints.reduce(math.max);
    final range = (maxAdc - minAdc) == 0 ? 1 : (maxAdc - minAdc);

    final stepX = size.width / math.max(adcPoints.length - 1, 1);

    for (int i = 0; i < adcPoints.length; i++) {
      final x = i * stepX;
      // Normalize ADC value to canvas height (leave 15% margin top/bottom)
      final norm = (adcPoints[i] - minAdc) / range;
      final y = size.height - (norm * (size.height * 0.7) + (size.height * 0.15));

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    // Glowing effect under path
    final glowPaint = Paint()
      ..color = (isTouchLost ? const Color(0xFFFF5252) : const Color(0xFF00E676)).withValues(alpha: 0.3)
      ..strokeWidth = 4.5
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, wavePaint);
  }

  @override
  bool shouldRepaint(covariant EcgWaveformPainter oldDelegate) {
    return oldDelegate.adcPoints != adcPoints || oldDelegate.isTouchLost != isTouchLost;
  }
}
