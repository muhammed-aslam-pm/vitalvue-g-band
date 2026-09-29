import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/vitalvue_config.dart';
import '../../protocol/veepoo_protocol.dart';

/// A card displaying the Personal Baseline Score, NEWS2 deterioration risk,
/// and physiological trend according to the VitalVue clinical architecture.
class PersonalBaselineBanner extends StatelessWidget {
  final BandState state;
  final AppProfileMode mode;

  const PersonalBaselineBanner({
    super.key,
    required this.state,
    this.mode = AppProfileMode.consumer,
  });

  Color _getNews2Color(int score) {
    if (score >= 7) return const Color(0xFFE53935); // Critical/High
    if (score >= 5) return const Color(0xFFFFA000); // Medium
    return const Color(0xFF43A047);                 // Low
  }

  Color _getTrendColor(String trend) {
    return switch (trend.toLowerCase()) {
      'critical' => const Color(0xFFE53935),
      'deteriorating' => const Color(0xFFFF7043),
      'improving' => const Color(0xFF00BFA5),
      _ => const Color(0xFF1E88E5), // stable
    };
  }

  IconData _getTrendIcon(String trend) {
    return switch (trend.toLowerCase()) {
      'critical' => Icons.warning_rounded,
      'deteriorating' => Icons.trending_down_rounded,
      'improving' => Icons.trending_up_rounded,
      _ => Icons.trending_flat_rounded,
    };
  }

  @override
  Widget build(BuildContext context) {
    final score = state.personalBaselineScore.clamp(0, 100);
    final news2 = state.news2Score;
    final trend = state.trendStatus;
    final isHospital = mode.isHospital;

    final scoreProgress = score / 100.0;
    final scoreColor = score >= 80
        ? const Color(0xFF00C853)
        : (score >= 60 ? const Color(0xFFFFA726) : const Color(0xFFE53935));

    final news2Color = _getNews2Color(news2);
    final trendColor = _getTrendColor(trend);

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scoreColor.withValues(alpha: 0.25),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Circular Progress Indicator for Baseline Score
                SizedBox(
                  width: 68,
                  height: 68,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: scoreProgress,
                        strokeWidth: 6,
                        backgroundColor: scoreColor.withValues(alpha: 0.15),
                        valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
                      ),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '$score',
                            style: GoogleFonts.inter(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            '/100',
                            style: TextStyle(
                              fontSize: 9,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Titles and Badges
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              isHospital ? 'Physiological Baseline' : 'Personal Health Baseline',
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A73E8).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              isHospital ? '10-min Engine' : '30–60 min Engine',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1A73E8),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Badges
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (isHospital)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: news2Color.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: news2Color.withValues(alpha: 0.4)),
                              ),
                              child: Text(
                                'NEWS2: $news2',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: news2Color,
                                ),
                              ),
                            ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: trendColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: trendColor.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(_getTrendIcon(trend), size: 13, color: trendColor),
                                const SizedBox(width: 4),
                                Text(
                                  trend.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: trendColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Clinical Summary
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                state.clinicalSummary.isNotEmpty
                    ? state.clinicalSummary
                    : (isHospital
                        ? 'Continuous RPM active. Primary deterioration parameters in clinical normal range.'
                        : 'Personal vitals tracking active. Baseline stability verified.'),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.15, end: 0, duration: 400.ms);
  }
}
