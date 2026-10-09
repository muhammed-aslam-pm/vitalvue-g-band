import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../bloc/patients_bloc.dart';
import '../../bloc/patients_state.dart';
import '../../cloud/assigned_patient.dart';
import '../../cloud/patient_baseline.dart';
import '../../cloud/patients_repository.dart';
import '../theme/app_theme.dart';

/// Metrics available for trending on the interactive deterioration timeline chart.
enum BaselineChartMetric {
  healthScore('Health Score', 'pts', AppColors.cyan),
  heartRate('Heart Rate', 'bpm', AppColors.red),
  spo2('SpO₂', '%', AppColors.cyan),
  bloodPressure('Blood Pressure', 'mmHg', AppColors.amber),
  temperature('Skin Temp', '°C', AppColors.purple);

  const BaselineChartMetric(this.label, this.unit, this.color);
  final String label;
  final String unit;
  final Color color;
}

class PatientBaselinePage extends StatefulWidget {
  const PatientBaselinePage({
    super.key,
    required this.patient,
  });

  final AssignedPatient patient;

  @override
  State<PatientBaselinePage> createState() => _PatientBaselinePageState();
}

class _PatientBaselinePageState extends State<PatientBaselinePage> {
  String _selectedRange = '24h';
  BaselineChartMetric _selectedMetric = BaselineChartMetric.healthScore;
  bool _isLoading = true;
  String? _errorMessage;

  PatientBaseline? _baseline;
  BaselineTimeline? _timeline;
  PatientIncidentTimeline? _incidentTimeline;

  final List<String> _ranges = const ['10m', '6h', '12h', '24h', '3d', '7d'];
  bool _isChartLoading = false;

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final repo = RepositoryProvider.of<PatientsRepository>(context);
    try {
      final results = await Future.wait([
        repo.fetchPatientBaseline(widget.patient.id, limit: 36),
        repo.fetchPatientBaselineTimeline(widget.patient.id, range: _selectedRange).catchError((e) {
          debugPrint('[PatientBaselinePage] Non-fatal: fetchPatientBaselineTimeline error: $e');
          return BaselineTimeline(
            patientId: widget.patient.id,
            mode: 'population',
            learningStable: 0,
            learningRequired: 12,
            confidence: 0.0,
            range: _selectedRange,
            hours: 24,
            resolutionMinutes: 10,
            tableStepMinutes: 120,
            points: const [],
            markers: const [],
            thresholdWithinBaseline: 80,
            thresholdDeterioration: 70,
            thresholdSignificant: 60,
            insights: const [],
            bands: const {},
          );
        }),
        repo.fetchPatientIncidentTimeline(widget.patient.id, limit: 10).catchError((e) {
          debugPrint('[PatientBaselinePage] Non-fatal: fetchPatientIncidentTimeline error: $e');
          return PatientIncidentTimeline(
            patientId: widget.patient.id,
            page: 1,
            totalAlerts: 0,
            alerts: const [],
          );
        }),
      ]);
      if (!mounted) return;

      final loadedBaseline = results[0] as PatientBaseline;
      final loadedTimeline = results[1] as BaselineTimeline;
      final loadedIncidents = results[2] as PatientIncidentTimeline;

      // If 24h timeline has 0 points but we have 10-minute interval observations,
      // default view to '10m' so staff immediately sees the recorded session curves!
      String initialRange = _selectedRange;
      if (loadedTimeline.points.isEmpty && loadedBaseline.observations.isNotEmpty) {
        initialRange = '10m';
      }

      // If health score is not yet calculated in learning mode, default metric to HR for immediate clinical value
      BaselineChartMetric metric = _selectedMetric;
      if (loadedBaseline.isLearning && (loadedTimeline.currentScore == null && loadedTimeline.usualScore == null)) {
        metric = BaselineChartMetric.heartRate;
      }

      setState(() {
        _baseline = loadedBaseline;
        _timeline = loadedTimeline;
        _incidentTimeline = loadedIncidents;
        _selectedRange = initialRange;
        _selectedMetric = metric;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _changeRange(String newRange) async {
    if (_selectedRange == newRange) return;
    setState(() {
      _selectedRange = newRange;
    });

    // 10m intervals are rendered from _baseline.observations
    if (newRange == '10m') {
      return;
    }

    setState(() {
      _isChartLoading = true;
    });

    final repo = RepositoryProvider.of<PatientsRepository>(context);
    try {
      final timeline = await repo.fetchPatientBaselineTimeline(widget.patient.id, range: newRange);
      if (!mounted) return;
      setState(() {
        _timeline = timeline;
        _isChartLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isChartLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Watch PatientsBloc so any live SSE vital updates automatically sync this patient
    final patientsState = context.watch<PatientsBloc>().state;
    final currentPatient = (patientsState is PatientsLoaded)
        ? patientsState.patients.firstWhere((p) => p.id == widget.patient.id, orElse: () => widget.patient)
        : widget.patient;

    final liveVitals = currentPatient.latestConnectedVitals ?? currentPatient.latestVitals;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: theme.colorScheme.onSurface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              currentPatient.fullName.trim(),
              style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            Text(
              'Room ${currentPatient.roomNo}  ·  ID: ${currentPatient.userId}',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh Baseline',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _isLoading ? null : () => _loadAllData(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading && _baseline == null
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null && _baseline == null
              ? _buildErrorView()
              : RefreshIndicator(
                  onRefresh: () => _loadAllData(),
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    children: [
                      // 1. Live Patient Clinical Summary Strip
                      _buildPatientSummaryStrip(context, currentPatient, liveVitals),
                      const SizedBox(height: 16),

                      // 2. Baseline Learning vs Active Hero Banner
                      if (_baseline != null) ...[
                        _buildBaselineStatusBanner(context, _baseline!),
                        const SizedBox(height: 16),
                      ],

                      // 3. Health Score & Score Components Card
                      _buildHealthScoreSection(context),
                      const SizedBox(height: 16),

                      // 4. Interactive Trend & Deterioration Chart (Multi-Metric)
                      _buildChartSection(context),
                      const SizedBox(height: 16),

                      // 5. Physiological Bands vs Current Reading
                      if (_baseline != null) ...[
                        _buildBandsSection(context, _baseline!, liveVitals),
                        const SizedBox(height: 16),
                      ],

                      // 6. Vitals at Each Interval (Mockup Panel 3 Matrix)
                      if (_baseline != null && _baseline!.observations.isNotEmpty) ...[
                        _buildIntervalMatrixSection(context, _baseline!.observations),
                        const SizedBox(height: 16),
                      ],

                      // 7. Clinical Baseline Insights & Audit
                      if (_timeline != null && _timeline!.insights.isNotEmpty) ...[
                        _buildInsightsSection(context, _timeline!.insights),
                        const SizedBox(height: 16),
                      ],

                      // 8. Clinical Incidents & Alerts Audit (Mockup Screen 6)
                      if (_incidentTimeline != null) ...[
                        _buildIncidentAlertsSection(context, _incidentTimeline!),
                        const SizedBox(height: 24),
                      ],
                    ],
                  ),
                ),
    );
  }

  // ── 1. Live Patient Summary Strip ──────────────────────────────────────────

  Widget _buildPatientSummaryStrip(
    BuildContext context,
    AssignedPatient patient,
    PatientVitalsSnapshot? vitals,
  ) {
    final theme = Theme.of(context);
    final isConnected = patient.isConnected;
    final isRemoved = patient.isRemoved;

    final Color statusColor;
    final String statusLabel;
    if (!isConnected) {
      statusColor = AppColors.textMuted;
      statusLabel = 'Disconnected';
    } else if (isRemoved) {
      statusColor = AppColors.red;
      statusLabel = 'Off-Wrist';
    } else {
      statusColor = AppColors.green;
      statusLabel = 'Live Monitoring';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.primary.withValues(alpha: 0.15),
            child: Text(
              patient.fullName.isNotEmpty ? patient.fullName.trim()[0].toUpperCase() : 'P',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    if (vitals != null && vitals.batteryPercent > 0) ...[
                      const SizedBox(width: 10),
                      Icon(Icons.battery_5_bar_rounded, size: 14, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                      const SizedBox(width: 2),
                      Text(
                        '${vitals.batteryPercent}%',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Age: ${patient.age > 0 ? patient.age : "--"}  ·  Gender: ${patient.gender.isNotEmpty ? patient.gender : "--"}  ·  Blood: ${patient.bloodGroup.isNotEmpty ? patient.bloodGroup : "--"}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 2. Baseline Learning vs Active Hero Banner ─────────────────────────────

  Widget _buildBaselineStatusBanner(BuildContext context, PatientBaseline baseline) {
    final isLearning = baseline.isLearning;
    final stable = baseline.learningStable;
    final required = baseline.learningRequired;
    final pct = (baseline.confidence * 100).toInt();

    final Color bannerColor = isLearning ? AppColors.primary : AppColors.green;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bannerColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: bannerColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isLearning ? Icons.psychology_rounded : Icons.verified_user_rounded,
                color: bannerColor,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isLearning
                      ? 'Baseline Calibration Phase ($stable/$required Windows)'
                      : 'Personalized Baseline Active',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: bannerColor,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: bannerColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$pct% Confidence',
                  style: TextStyle(
                    color: bannerColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: baseline.learningProgress,
              backgroundColor: bannerColor.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(bannerColor),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            isLearning
                ? 'VitalVue requires 12 stable 10-minute resting intervals to construct this patient’s individual baseline signature. Standard clinical population safeguard bands are actively protecting the patient until calibration completes.'
                : 'Individual resting baseline is established. Real-time deviations from this patient’s unique physiological norm are continuously tracked to detect early decompensation.',
            style: const TextStyle(
              fontSize: 12,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // ── 3. Health Score Section ────────────────────────────────────────────────

  Widget _buildHealthScoreSection(BuildContext context) {
    final theme = Theme.of(context);
    final score = _timeline?.currentScore ?? _timeline?.usualScore;
    final scoreTrend = _timeline?.scoreTrend ?? 'Stable';

    final Color scoreColor;
    final String statusLabel;
    if (score == null) {
      scoreColor = AppColors.cyan;
      statusLabel = 'Calibrating Baseline';
    } else if (score >= 80) {
      scoreColor = AppColors.green;
      statusLabel = 'Within Patient Baseline';
    } else if (score >= 70) {
      scoreColor = AppColors.amber;
      statusLabel = 'Mild Baseline Variance';
    } else {
      scoreColor = AppColors.red;
      statusLabel = 'Clinical Deterioration Warning';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          // Circular Score Widget
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scoreColor.withValues(alpha: 0.1),
              border: Border.all(color: scoreColor, width: 3),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    score != null ? score.toInt().toString() : '--',
                    style: GoogleFonts.inter(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: scoreColor,
                    ),
                  ),
                  Text(
                    '/100',
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Score Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Overall Health Score',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scoreColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: scoreColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      scoreTrend.toLowerCase() == 'deteriorating'
                          ? Icons.trending_down_rounded
                          : Icons.trending_flat_rounded,
                      size: 16,
                      color: scoreTrend.toLowerCase() == 'deteriorating'
                          ? AppColors.red
                          : AppColors.green,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Trend: $scoreTrend (vs previous interval)',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 4. Interactive Trend & Deterioration Chart ──────────────────────────────

  Widget _buildChartSection(BuildContext context) {
    final theme = Theme.of(context);

    // Collect data points for the selected metric
    final timelinePoints = _timeline?.points ?? [];
    final observations = _baseline?.observations ?? [];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section Title
          Text(
            'Clinical Deterioration Graph',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 10),

          // Range Filter Pills (Scrollable row preventing overflow on all screens)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _ranges.map((r) {
                final isSelected = _selectedRange == r;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () => _changeRange(r),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.cardBorder,
                        ),
                      ),
                      child: Text(
                        r,
                        style: TextStyle(
                          color: isSelected
                              ? Colors.white
                              : AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 10),

          // Metric Switcher Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: BaselineChartMetric.values.map((m) {
                final isSelected = _selectedMetric == m;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    selected: isSelected,
                    label: Text(m.label),
                    labelStyle: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected ? Colors.white : AppColors.textSecondary,
                    ),
                    selectedColor: m.color,
                    backgroundColor: AppColors.surfaceElevated,
                    side: BorderSide(
                      color: isSelected ? m.color : AppColors.cardBorder,
                    ),
                    checkmarkColor: Colors.white,
                    showCheckmark: false,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    onSelected: (val) {
                      setState(() {
                        _selectedMetric = m;
                      });
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),

          // Chart Legends
          _buildMetricLegend(_selectedMetric),
          const SizedBox(height: 14),

          // Line Chart with dedicated loading indicator
          if (_isChartLoading)
            Container(
              height: 220,
              alignment: Alignment.center,
              child: const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          else
            _buildChartForMetric(context, timelinePoints, observations),
        ],
      ),
    );
  }

  Widget _buildMetricLegend(BaselineChartMetric metric) {
    switch (metric) {
      case BaselineChartMetric.healthScore:
        return Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _buildLegendItem(AppColors.cyan, 'Health Score'),
            _buildLegendItem(AppColors.green, 'Baseline Norm (80)', isDashed: true),
            _buildLegendItem(AppColors.red, 'Deterioration (70)', isDashed: true),
          ],
        );
      case BaselineChartMetric.heartRate:
        return Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _buildLegendItem(AppColors.red, 'Heart Rate (bpm)'),
            _buildLegendItem(AppColors.amber, 'Resting High (100)', isDashed: true),
            _buildLegendItem(AppColors.cyan, 'Resting Low (60)', isDashed: true),
          ],
        );
      case BaselineChartMetric.spo2:
        return Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _buildLegendItem(AppColors.cyan, 'SpO₂ (%)'),
            _buildLegendItem(AppColors.red, 'Safe Limit (≥ 94%)', isDashed: true),
          ],
        );
      case BaselineChartMetric.bloodPressure:
        return Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _buildLegendItem(AppColors.amber, 'Systolic BP (SBP)'),
            _buildLegendItem(AppColors.purple, 'Diastolic BP (DBP)'),
          ],
        );
      case BaselineChartMetric.temperature:
        return Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _buildLegendItem(AppColors.purple, 'Skin Temp (°C)'),
            _buildLegendItem(AppColors.green, 'Norm (36.5°C)', isDashed: true),
          ],
        );
    }
  }

  Widget _buildLegendItem(Color color, String label, {bool isDashed = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: isDashed ? 2 : 4,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildChartForMetric(
    BuildContext context,
    List<BaselineTimelinePoint> timelinePoints,
    List<BaselineObservation> observations,
  ) {
    // If Health Score is selected and points have no scores (calibrating mode), provide advice
    if (_selectedMetric == BaselineChartMetric.healthScore) {
      final validScorePoints = timelinePoints.where((p) => p.score != null).toList();
      if (validScorePoints.isEmpty) {
        return Container(
          height: 180,
          padding: const EdgeInsets.all(16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.psychology_rounded, size: 36, color: Color(0xFF0288D1)),
              const SizedBox(height: 8),
              const Text(
                'Health Score is Calibrating',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'This patient is currently accumulating 12 resting intervals.\nSelect "Heart Rate" or "SpO₂" above to inspect physiological curves.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
            ],
          ),
        );
      }
    }

    // Prepare spots from either 10-minute observations or timeline points
    final spots1 = <FlSpot>[];
    final spots2 = <FlSpot>[]; // for DBP in blood pressure
    final dates = <DateTime>[];

    if (_selectedRange == '10m') {
      // 10-minute interval observations from baseline session
      final validObs = observations.where((o) => o.windowStart != null).toList()
        ..sort((a, b) => a.windowStart!.compareTo(b.windowStart!));
      for (final obs in validObs) {
        if (!obs.isStable && obs.hr == null && obs.spo2 == null) continue;
        final val = _getObservationValue(obs, _selectedMetric);
        if (val != null) {
          spots1.add(FlSpot(spots1.length.toDouble(), val));
          dates.add(obs.windowStart!);
        }
        if (_selectedMetric == BaselineChartMetric.bloodPressure && obs.dbp != null) {
          spots2.add(FlSpot(spots2.length.toDouble(), obs.dbp!));
        }
      }
    } else if (timelinePoints.isNotEmpty) {
      for (int i = 0; i < timelinePoints.length; i++) {
        final p = timelinePoints[i];
        final val = _getTimelinePointValue(p, _selectedMetric);
        if (val != null) {
          spots1.add(FlSpot(spots1.length.toDouble(), val));
          dates.add(p.t);
        }
        if (_selectedMetric == BaselineChartMetric.bloodPressure) {
          final dbp = p.values['dbp'];
          if (dbp != null) {
            spots2.add(FlSpot(spots2.length.toDouble(), dbp));
          }
        }
      }
    }

    if (spots1.isEmpty) {
      final hasObservations = observations.any((o) => o.isStable);
      return Container(
        height: 200,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.history_toggle_off_rounded,
              size: 38,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.28),
            ),
            const SizedBox(height: 8),
            Text(
              'No ${_selectedMetric.label} data recorded in the last $_selectedRange.',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              hasObservations
                  ? 'Last monitored session was Oct 2, 2026 (${observations.where((o) => o.isStable).length} resting intervals).'
                  : 'No resting baseline intervals recorded yet for this patient.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
            if (hasObservations) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.av_timer_rounded, size: 15),
                    label: const Text('View 10m Intervals', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                    onPressed: () => _changeRange('10m'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.date_range_rounded, size: 15),
                    label: const Text('View 7d Range', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                    onPressed: () => _changeRange('7d'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    }

    // Compute Y-axis bounds safely
    double minY = spots1.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    double maxY = spots1.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    if (_selectedMetric == BaselineChartMetric.bloodPressure && spots2.isNotEmpty) {
      final minDbp = spots2.map((s) => s.y).reduce((a, b) => a < b ? a : b);
      if (minDbp < minY) minY = minDbp;
      final maxDbp = spots2.map((s) => s.y).reduce((a, b) => a > b ? a : b);
      if (maxDbp > maxY) maxY = maxDbp;
    }

    if (_selectedMetric == BaselineChartMetric.healthScore) {
      minY = 0;
      maxY = 100;
    } else if (_selectedMetric == BaselineChartMetric.spo2) {
      minY = (minY - 2).clamp(80, 100);
      maxY = 100;
    } else if (_selectedMetric == BaselineChartMetric.heartRate) {
      minY = (minY - 10).clamp(40, 150);
      maxY = (maxY + 10).clamp(60, 200);
    } else {
      minY = (minY * 0.95).floorToDouble();
      maxY = (maxY * 1.05).ceilToDouble();
      if (maxY - minY < 4) {
        minY -= 2;
        maxY += 2;
      }
    }

    // Threshold lines
    final extraLines = <HorizontalLine>[];
    if (_selectedMetric == BaselineChartMetric.healthScore) {
      extraLines.addAll([
        HorizontalLine(y: 80, color: AppColors.green.withValues(alpha: 0.6), strokeWidth: 1.5, dashArray: [5, 4]),
        HorizontalLine(y: 70, color: AppColors.red.withValues(alpha: 0.6), strokeWidth: 1.5, dashArray: [5, 4]),
      ]);
    } else if (_selectedMetric == BaselineChartMetric.heartRate) {
      extraLines.addAll([
        HorizontalLine(y: 100, color: AppColors.amber.withValues(alpha: 0.6), strokeWidth: 1.5, dashArray: [5, 4]),
        HorizontalLine(y: 60, color: AppColors.cyan.withValues(alpha: 0.6), strokeWidth: 1.5, dashArray: [5, 4]),
      ]);
    } else if (_selectedMetric == BaselineChartMetric.spo2) {
      extraLines.add(
        HorizontalLine(y: 94, color: AppColors.red.withValues(alpha: 0.6), strokeWidth: 1.5, dashArray: [5, 4]),
      );
    }

    final lineBars = <LineChartBarData>[
      LineChartBarData(
        spots: spots1,
        isCurved: spots1.length > 2,
        curveSmoothness: 0.2,
        color: _selectedMetric.color,
        barWidth: 3,
        isStrokeCapRound: true,
        dotData: FlDotData(
          show: true,
          getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
            radius: spots1.length == 1 ? 6.0 : 3.5,
            color: _selectedMetric.color,
            strokeWidth: spots1.length == 1 ? 3 : 2,
            strokeColor: Colors.white,
          ),
        ),
        belowBarData: BarAreaData(
          show: true,
          color: _selectedMetric.color.withValues(alpha: 0.12),
        ),
      ),
    ];

    if (_selectedMetric == BaselineChartMetric.bloodPressure && spots2.isNotEmpty) {
      lineBars.add(
        LineChartBarData(
          spots: spots2,
          isCurved: spots2.length > 2,
          curveSmoothness: 0.2,
          color: AppColors.purple,
          barWidth: 2.5,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
              radius: spots2.length == 1 ? 5.5 : 3,
              color: AppColors.purple,
              strokeWidth: spots2.length == 1 ? 2.5 : 1.5,
              strokeColor: Colors.white,
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);

    return Column(
      children: [
        SizedBox(
          height: 220,
          child: LineChart(
            LineChartData(
              minY: minY,
              maxY: maxY,
              minX: spots1.length == 1 ? -0.5 : 0.0,
              maxX: spots1.length == 1 ? 0.5 : (spots1.length - 1).toDouble(),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (val) => const FlLine(
                  color: AppColors.cardBorder,
                  strokeWidth: 1,
                ),
              ),
              extraLinesData: ExtraLinesData(horizontalLines: extraLines),
              titlesData: FlTitlesData(
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    interval: (maxY - minY) > 10 ? ((maxY - minY) / 4).ceilToDouble() : 5,
                    getTitlesWidget: (val, meta) => Text(
                      val.toInt().toString(),
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: (_selectedRange == '3d' || _selectedRange == '7d') ? 32 : 24,
                    interval: spots1.length == 1
                        ? 1.0
                        : (spots1.length > 5 ? (spots1.length / 4).ceilToDouble() : 1.0),
                    getTitlesWidget: (val, meta) {
                      final idx = val.toInt();
                      if (spots1.length == 1) {
                        if (val != 0) return const SizedBox.shrink();
                        final t = dates.isNotEmpty ? dates[0] : null;
                        if (t == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            DateFormat('MMM d\nHH:mm').format(t),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 9,
                              height: 1.1,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        );
                      }
                      if (idx < 0 || idx >= dates.length) return const SizedBox.shrink();
                      final t = dates[idx];
                      final label = (_selectedRange == '3d' || _selectedRange == '7d')
                          ? DateFormat('MMM d\nHH:mm').format(t)
                          : DateFormat('HH:mm').format(t);
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 9,
                            height: 1.1,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              borderData: FlBorderData(show: false),
              lineBarsData: lineBars,
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (touchedSpots) {
                    return touchedSpots.map((spot) {
                      final idx = spot.spotIndex;
                      final t = idx < dates.length ? dates[idx] : null;
                      final dateStr = t != null ? DateFormat('MMM d, HH:mm').format(t) : '';
                      return LineTooltipItem(
                        '${_selectedMetric.label}: ${spot.y.toStringAsFixed(1)} ${_selectedMetric.unit}\n$dateStr',
                        const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      );
                    }).toList();
                  },
                ),
              ),
            ),
          ),
        ),
        if (spots1.length == 1) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 14, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '1 hourly average recorded (${DateFormat('MMM d, HH:mm').format(dates.first)}: ${spots1.first.y.toStringAsFixed(1)} ${_selectedMetric.unit}).',
                    style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
                  ),
                ),
                if (_selectedRange != '10m' && observations.any((o) => o.isStable))
                  InkWell(
                    onTap: () => _changeRange('10m'),
                    child: const Text(
                      'View 10m intervals →',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF1A73E8)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  double? _getObservationValue(BaselineObservation obs, BaselineChartMetric metric) {
    switch (metric) {
      case BaselineChartMetric.healthScore:
        return null;
      case BaselineChartMetric.heartRate:
        return obs.hr;
      case BaselineChartMetric.spo2:
        return obs.spo2;
      case BaselineChartMetric.bloodPressure:
        return obs.sbp;
      case BaselineChartMetric.temperature:
        return obs.temp;
    }
  }

  double? _getTimelinePointValue(BaselineTimelinePoint p, BaselineChartMetric metric) {
    switch (metric) {
      case BaselineChartMetric.healthScore:
        return p.score;
      case BaselineChartMetric.heartRate:
        return p.values['hr'];
      case BaselineChartMetric.spo2:
        return p.values['spo2'];
      case BaselineChartMetric.bloodPressure:
        return p.values['sbp'];
      case BaselineChartMetric.temperature:
        return p.values['temp'];
    }
  }

  // ── 5. Physiological Bands vs Current Readings ────────────────────────────

  Widget _buildBandsSection(BuildContext context, PatientBaseline baseline, PatientVitalsSnapshot? liveVitals) {
    final theme = Theme.of(context);
    final bands = baseline.bands;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Physiological Baseline Bands',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: baseline.mode == 'individual'
                      ? AppColors.green.withValues(alpha: 0.15)
                      : AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  baseline.mode == 'individual' ? 'Personal Norm Active' : 'Population Safe Band',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: baseline.mode == 'individual' ? AppColors.green : AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildBandRow(
            context,
            icon: Icons.favorite_rounded,
            color: AppColors.red,
            label: 'Heart Rate',
            currentVal: liveVitals != null && liveVitals.heartRate > 0 ? '${liveVitals.heartRate} bpm' : '--',
            bandText: bands['hr']?.formatRange(unit: 'bpm') ?? '60–100 bpm',
            isWithin: liveVitals != null && liveVitals.heartRate >= 60 && liveVitals.heartRate <= 100,
          ),
          const Divider(height: 16),
          _buildBandRow(
            context,
            icon: Icons.water_drop_rounded,
            color: AppColors.cyan,
            label: 'Blood Oxygen (SpO₂)',
            currentVal: liveVitals != null && liveVitals.spo2 > 0 ? '${liveVitals.spo2.toInt()}%' : '--',
            bandText: bands['spo2']?.formatRange(unit: '%') ?? '≥ 94%',
            isWithin: liveVitals != null && liveVitals.spo2 >= 94,
          ),
          const Divider(height: 16),
          _buildBandRow(
            context,
            icon: Icons.speed_rounded,
            color: AppColors.amber,
            label: 'Blood Pressure (Sys/Dia)',
            currentVal: liveVitals != null && (liveVitals.bpSystolic > 0 || liveVitals.bpDiastolic > 0)
                ? '${liveVitals.bpSystolic}/${liveVitals.bpDiastolic} mmHg'
                : '--',
            bandText: 'SBP 100–140  ·  DBP 60–90',
            isWithin: liveVitals != null &&
                liveVitals.bpSystolic >= 100 &&
                liveVitals.bpSystolic <= 140 &&
                liveVitals.bpDiastolic >= 60 &&
                liveVitals.bpDiastolic <= 90,
          ),
          const Divider(height: 16),
          _buildBandRow(
            context,
            icon: Icons.thermostat_rounded,
            color: AppColors.purple,
            label: 'Skin Temperature',
            currentVal: liveVitals != null && liveVitals.temp > 0 ? '${liveVitals.temp.toStringAsFixed(1)} °C' : '--',
            bandText: '32.0–37.5 °C',
            isWithin: liveVitals != null && liveVitals.temp >= 32.0 && liveVitals.temp <= 37.5,
          ),
        ],
      ),
    );
  }

  Widget _buildBandRow(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    required String currentVal,
    required String bandText,
    required bool isWithin,
  }) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Baseline Target: $bandText',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              currentVal,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isWithin
                    ? AppColors.green.withValues(alpha: 0.12)
                    : AppColors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isWithin ? 'In Band' : 'Check',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: isWithin ? AppColors.green : AppColors.amber,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── 6. Vitals at Each Interval (Mockup Panel 3 Matrix) ──────────────────────

  Widget _buildIntervalMatrixSection(BuildContext context, List<BaselineObservation> observations) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Vitals at Each Interval',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              Text(
                '10-Minute Windows (${observations.length})',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Scrollable Matrix Table matching Mockup Panel 3
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 18,
              horizontalMargin: 0,
              headingRowHeight: 36,
              dataRowMinHeight: 44,
              dataRowMaxHeight: 48,
              columns: const [
                DataColumn(label: Text('Interval', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                DataColumn(label: Text('Calibration', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                DataColumn(label: Text('HR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                DataColumn(label: Text('SpO₂', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                DataColumn(label: Text('BP (Sys/Dia)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                DataColumn(label: Text('Temp', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                DataColumn(label: Text('Signal', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                DataColumn(label: Text('Samples', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              ],
              rows: observations.map((obs) {
                final timeStr = obs.windowStart != null ? DateFormat('HH:mm').format(obs.windowStart!) : '--';
                final isStable = obs.isStable;
                final hrStr = obs.hr != null ? '${obs.hr!.toInt()} bpm' : '--';
                final spo2Str = obs.spo2 != null ? '${obs.spo2!.toInt()}%' : '--';
                final bpStr = (obs.sbp != null && obs.dbp != null) ? '${obs.sbp!.toInt()}/${obs.dbp!.toInt()}' : '--';
                final tempStr = obs.temp != null ? '${obs.temp!.toStringAsFixed(1)}°' : '--';
                final signalQuality = obs.signalQuality.toUpperCase();

                return DataRow(
                  cells: [
                    DataCell(Text(timeStr, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                    DataCell(
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isStable
                              ? AppColors.green.withValues(alpha: 0.12)
                              : AppColors.red.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isStable ? 'Calibrated' : 'Rejected',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: isStable ? AppColors.green : AppColors.red,
                          ),
                        ),
                      ),
                    ),
                    DataCell(Text(hrStr, style: const TextStyle(fontSize: 12))),
                    DataCell(Text(spo2Str, style: const TextStyle(fontSize: 12))),
                    DataCell(Text(bpStr, style: const TextStyle(fontSize: 12))),
                    DataCell(Text(tempStr, style: const TextStyle(fontSize: 12))),
                    DataCell(
                      Text(
                        signalQuality,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: signalQuality == 'GOOD'
                              ? AppColors.green
                              : AppColors.amber,
                        ),
                      ),
                    ),
                    DataCell(
                      Text(
                        '${obs.sampleCount}',
                        style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ── 7. Clinical Insights Section ───────────────────────────────────────────

  Widget _buildInsightsSection(BuildContext context, List<Map<String, dynamic>> insights) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline_rounded, color: AppColors.amber, size: 20),
              const SizedBox(width: 8),
              Text(
                'Clinical Baseline Insights',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...insights.map((insight) {
            final type = insight['type']?.toString() ?? '';
            String message = '';
            IconData icon = Icons.info_outline_rounded;
            Color color = AppColors.primary;

            switch (type) {
              case 'learning':
                final stable = insight['stable'];
                final req = insight['required'];
                message = 'Baseline calibration is active: $stable of $req stable resting periods recorded.';
                icon = Icons.hourglass_top_rounded;
                color = AppColors.cyan;
                break;
              case 'kept_out':
                final total = insight['total'] ?? 0;
                message = '$total 10-minute intervals excluded from baseline calibration due to artifact or patient movement.';
                icon = Icons.motion_photos_off_rounded;
                color = AppColors.amber;
                break;
              case 'no_data':
                final hours = insight['hours'] ?? 24;
                message = 'No continuous stream recorded within the past $hours hours.';
                icon = Icons.cloud_off_rounded;
                color = AppColors.textMuted;
                break;
              case 'deterioration':
                message = insight['message']?.toString() ?? 'Health score dipped below deterioration threshold.';
                icon = Icons.warning_amber_rounded;
                color = AppColors.red;
                break;
              default:
                message = insight['message']?.toString() ?? 'Observation logged.';
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: color, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── 8. Clinical Incidents & Alerts Audit (Mockup Screen 6) ────────────────

  Widget _buildIncidentAlertsSection(BuildContext context, PatientIncidentTimeline incidentTimeline) {
    final theme = Theme.of(context);
    final alerts = incidentTimeline.alerts;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.notifications_active_outlined, color: AppColors.red, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Clinical Incidents & Alerts',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (alerts.isEmpty ? AppColors.green : AppColors.red).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${alerts.length} Total',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: alerts.isEmpty ? AppColors.green : AppColors.red,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (alerts.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.green.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                children: [
                  Icon(Icons.check_circle_outline_rounded, color: AppColors.green, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No critical incidents recorded. Patient vitals remain stable.',
                      style: TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            )
          else
            ...alerts.map((alert) {
              final isResolved = alert.isResolved;
              final isCritical = alert.severity.toLowerCase() == 'critical';
              final timeStr = alert.createdAt != null
                  ? DateFormat('MMM d, HH:mm').format(alert.createdAt!)
                  : '--';

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (isCritical ? AppColors.red : AppColors.amber).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (isCritical ? AppColors.red : AppColors.amber).withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isCritical ? Icons.emergency_rounded : Icons.warning_amber_rounded,
                          color: isCritical ? AppColors.red : AppColors.amber,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${alert.vitalType}: ${alert.triggeredValue}',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isResolved
                                ? AppColors.green.withValues(alpha: 0.15)
                                : AppColors.red.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            isResolved ? 'Resolved' : 'Active',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: isResolved ? AppColors.green : AppColors.red,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Triggered at: $timeStr',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    if (alert.actionsTaken.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: alert.actionsTaken.map((act) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 2.0),
                              child: Row(
                                children: [
                                  const Icon(Icons.done_all_rounded, size: 14, color: AppColors.green),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Action Taken: ${act.actionType}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  // ── Error View ─────────────────────────────────────────────────────────────

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48, color: AppColors.red),
            const SizedBox(height: 16),
            Text(
              'Unable to load baseline',
              style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? 'Unknown error occurred.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _loadAllData(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }
}
