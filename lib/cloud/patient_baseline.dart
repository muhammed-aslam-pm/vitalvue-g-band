String? _extractString(dynamic val) {
  if (val == null) return null;
  if (val is String) return val;
  if (val is Map) {
    return val['name']?.toString() ??
        val['label']?.toString() ??
        val['band']?.toString() ??
        val['kind']?.toString() ??
        val['trend']?.toString() ??
        val['direction']?.toString() ??
        val['reason']?.toString() ??
        val['message']?.toString() ??
        (val.values.isNotEmpty ? val.values.first?.toString() : null);
  }
  return val.toString();
}

class BaselineBand {
  const BaselineBand({
    required this.kind,
    this.center,
    this.low,
    this.high,
  });

  final String kind;
  final double? center;
  final double? low;
  final double? high;

  factory BaselineBand.fromJson(Map<String, dynamic> j) {
    return BaselineBand(
      kind: _extractString(j['kind']) ?? 'population',
      center: (j['center'] as num?)?.toDouble(),
      low: (j['low'] as num?)?.toDouble(),
      high: (j['high'] as num?)?.toDouble(),
    );
  }

  String formatRange({String unit = ''}) {
    if (low != null && high != null) {
      return '${low!.toInt()}–${high!.toInt()} $unit'.trim();
    } else if (low != null) {
      return '≥ ${low!.toInt()} $unit'.trim();
    } else if (high != null) {
      return '≤ ${high!.toInt()} $unit'.trim();
    }
    return 'Standard';
  }
}

class BaselineObservation {
  const BaselineObservation({
    required this.windowStart,
    required this.sampleCount,
    this.hr,
    this.spo2,
    this.sbp,
    this.dbp,
    this.mapVal,
    this.hrv,
    this.stress,
    this.temp,
    required this.signalQuality,
    this.activityState,
    required this.isStable,
    this.rejectReason,
    required this.status,
  });

  final DateTime? windowStart;
  final int sampleCount;
  final double? hr;
  final double? spo2;
  final double? sbp;
  final double? dbp;
  final double? mapVal;
  final double? hrv;
  final double? stress;
  final double? temp;
  final String signalQuality;
  final String? activityState;
  final bool isStable;
  final String? rejectReason;
  final Map<String, String> status;

  factory BaselineObservation.fromJson(Map<String, dynamic> j) {
    DateTime? dt;
    if (j['window_start'] != null) {
      try {
        dt = DateTime.parse(j['window_start'].toString());
      } catch (_) {}
    }

    final rawStatus = j['status'];
    final Map<String, String> statusMap = {};
    if (rawStatus is Map) {
      rawStatus.forEach((k, v) {
        statusMap[k.toString()] = _extractString(v) ?? '';
      });
    } else if (rawStatus != null) {
      statusMap['overall'] = rawStatus.toString();
    }

    return BaselineObservation(
      windowStart: dt,
      sampleCount: (j['sample_count'] as num?)?.toInt() ?? 0,
      hr: (j['hr'] as num?)?.toDouble(),
      spo2: (j['spo2'] as num?)?.toDouble(),
      sbp: (j['sbp'] as num?)?.toDouble(),
      dbp: (j['dbp'] as num?)?.toDouble(),
      mapVal: (j['map'] as num?)?.toDouble(),
      hrv: (j['hrv'] as num?)?.toDouble(),
      stress: (j['stress'] as num?)?.toDouble(),
      temp: (j['temp'] as num?)?.toDouble(),
      signalQuality: _extractString(j['signal_quality']) ?? 'good',
      activityState: _extractString(j['activity_state']),
      isStable: j['is_stable'] as bool? ?? false,
      rejectReason: _extractString(j['reject_reason']),
      status: statusMap,
    );
  }

  bool get isRejected => !isStable || rejectReason != null;

  String get displayRejectReason {
    if (rejectReason == null) return '';
    switch (rejectReason) {
      case 'poor_signal':
        return 'Poor signal quality / sensor movement';
      case 'activity':
        return 'Patient was active / non-resting';
      default:
        return rejectReason!.replaceAll('_', ' ');
    }
  }
}

class PatientBaseline {
  const PatientBaseline({
    required this.patientId,
    required this.mode,
    required this.version,
    this.episodeStart,
    this.windowStart,
    required this.learningStable,
    required this.learningRequired,
    required this.confidence,
    required this.bands,
    required this.observations,
  });

  final int patientId;
  final String mode; // 'population' or 'individual'
  final int version;
  final DateTime? episodeStart;
  final DateTime? windowStart;
  final int learningStable;
  final int learningRequired;
  final double confidence;
  final Map<String, BaselineBand> bands;
  final List<BaselineObservation> observations;

  factory PatientBaseline.fromJson(Map<String, dynamic> j) {
    final rawLearning = j['learning'] as Map<String, dynamic>? ?? {};
    final rawBands = j['bands'] as Map<String, dynamic>? ?? {};
    final rawObs = j['observations'] as List<dynamic>? ?? [];

    DateTime? epStart;
    if (j['episode_start'] != null) {
      try {
        epStart = DateTime.parse(j['episode_start'].toString());
      } catch (_) {}
    }

    DateTime? winStart;
    if (j['window_start'] != null) {
      try {
        winStart = DateTime.parse(j['window_start'].toString());
      } catch (_) {}
    }

    final bands = <String, BaselineBand>{};
    rawBands.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        bands[k] = BaselineBand.fromJson(v);
      }
    });

    final observations = rawObs
        .whereType<Map<String, dynamic>>()
        .map(BaselineObservation.fromJson)
        .toList();

    return PatientBaseline(
      patientId: (j['patient_id'] as num?)?.toInt() ?? 0,
      mode: _extractString(j['mode']) ?? 'population',
      version: (j['version'] as num?)?.toInt() ?? 1,
      episodeStart: epStart,
      windowStart: winStart,
      learningStable: (rawLearning['stable'] as num?)?.toInt() ?? 0,
      learningRequired: (rawLearning['required'] as num?)?.toInt() ?? 12,
      confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
      bands: bands,
      observations: observations,
    );
  }

  bool get isLearning => mode == 'population' || learningStable < learningRequired;
  double get learningProgress => learningRequired > 0
      ? (learningStable / learningRequired).clamp(0.0, 1.0)
      : 1.0;
}

class BaselineTimelinePoint {
  const BaselineTimelinePoint({
    required this.t,
    this.score,
    required this.values,
    required this.status,
    required this.windows,
    required this.used,
    this.rejectReason,
  });

  final DateTime t;
  final double? score;
  final Map<String, double?> values;
  final Map<String, String?> status;
  final int windows;
  final int used;
  final String? rejectReason;

  factory BaselineTimelinePoint.fromJson(Map<String, dynamic> j) {
    DateTime time = DateTime.now();
    if (j['t'] != null) {
      try {
        time = DateTime.parse(j['t'].toString());
      } catch (_) {}
    }

    final rawValues = j['values'];
    final Map<String, double?> valuesMap = {};
    if (rawValues is Map) {
      rawValues.forEach((k, v) {
        valuesMap[k.toString()] = (v as num?)?.toDouble();
      });
    }

    final rawStatus = j['status'];
    final Map<String, String?> statusMap = {};
    if (rawStatus is Map) {
      rawStatus.forEach((k, v) {
        statusMap[k.toString()] = _extractString(v);
      });
    } else if (rawStatus != null) {
      statusMap['overall'] = rawStatus.toString();
    }

    return BaselineTimelinePoint(
      t: time,
      score: (j['score'] as num?)?.toDouble(),
      values: valuesMap,
      status: statusMap,
      windows: (j['windows'] as num?)?.toInt() ?? 0,
      used: (j['used'] as num?)?.toInt() ?? 0,
      rejectReason: _extractString(j['reject_reason']),
    );
  }
}

class BaselineTimelineMarker {
  const BaselineTimelineMarker({
    required this.t,
    this.score,
    required this.type,
    this.message,
  });

  final DateTime t;
  final double? score;
  final String type;
  final String? message;

  factory BaselineTimelineMarker.fromJson(Map<String, dynamic> j) {
    DateTime time = DateTime.now();
    if (j['t'] != null) {
      try {
        time = DateTime.parse(j['t'].toString());
      } catch (_) {}
    }

    return BaselineTimelineMarker(
      t: time,
      score: (j['score'] as num?)?.toDouble(),
      type: _extractString(j['type']) ?? 'alert',
      message: _extractString(j['message']) ?? _extractString(j['label']),
    );
  }
}

class BaselineTimeline {
  const BaselineTimeline({
    required this.patientId,
    required this.mode,
    required this.learningStable,
    required this.learningRequired,
    required this.confidence,
    required this.range,
    required this.hours,
    required this.resolutionMinutes,
    required this.tableStepMinutes,
    this.start,
    this.end,
    required this.points,
    required this.markers,
    this.usualScore,
    this.currentScore,
    this.currentBand,
    this.scoreTrend,
    required this.thresholdWithinBaseline,
    required this.thresholdDeterioration,
    required this.thresholdSignificant,
    required this.insights,
    required this.bands,
  });

  final int patientId;
  final String mode;
  final int learningStable;
  final int learningRequired;
  final double confidence;
  final String range;
  final int hours;
  final int resolutionMinutes;
  final int tableStepMinutes;
  final DateTime? start;
  final DateTime? end;
  final List<BaselineTimelinePoint> points;
  final List<BaselineTimelineMarker> markers;
  final double? usualScore;
  final double? currentScore;
  final String? currentBand;
  final String? scoreTrend;
  final double thresholdWithinBaseline;
  final double thresholdDeterioration;
  final double thresholdSignificant;
  final List<Map<String, dynamic>> insights;
  final Map<String, BaselineBand> bands;

  factory BaselineTimeline.fromJson(Map<String, dynamic> j) {
    final rawLearning = j['learning'] as Map<String, dynamic>? ?? {};
    final rawPoints = j['points'] as List<dynamic>? ?? [];
    final rawMarkers = j['markers'] as List<dynamic>? ?? [];
    final rawInsights = j['insights'] as List<dynamic>? ?? [];
    final rawThresholds = j['thresholds'] as Map<String, dynamic>? ?? {};
    final rawBands = j['bands'] as Map<String, dynamic>? ?? {};
    final rawCurrent = j['current'] as Map<String, dynamic>? ?? {};

    DateTime? startTime;
    if (j['start'] != null) {
      try {
        startTime = DateTime.parse(j['start'].toString());
      } catch (_) {}
    }

    DateTime? endTime;
    if (j['end'] != null) {
      try {
        endTime = DateTime.parse(j['end'].toString());
      } catch (_) {}
    }

    final bands = <String, BaselineBand>{};
    rawBands.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        bands[k] = BaselineBand.fromJson(v);
      }
    });

    final points = rawPoints
        .whereType<Map<String, dynamic>>()
        .map(BaselineTimelinePoint.fromJson)
        .toList();

    final markers = rawMarkers
        .whereType<Map<String, dynamic>>()
        .map(BaselineTimelineMarker.fromJson)
        .toList();

    final insights = rawInsights.whereType<Map<String, dynamic>>().toList();

    return BaselineTimeline(
      patientId: (j['patient_id'] as num?)?.toInt() ?? 0,
      mode: _extractString(j['mode']) ?? 'population',
      learningStable: (rawLearning['stable'] as num?)?.toInt() ?? 0,
      learningRequired: (rawLearning['required'] as num?)?.toInt() ?? 12,
      confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
      range: _extractString(j['range']) ?? '24h',
      hours: (j['hours'] as num?)?.toInt() ?? 24,
      resolutionMinutes: (j['resolution_minutes'] as num?)?.toInt() ?? 10,
      tableStepMinutes: (j['table_step_minutes'] as num?)?.toInt() ?? 120,
      start: startTime,
      end: endTime,
      points: points,
      markers: markers,
      usualScore: (j['usual_score'] as num?)?.toDouble(),
      currentScore: (rawCurrent['score'] as num?)?.toDouble(),
      currentBand: _extractString(rawCurrent['band']),
      scoreTrend: _extractString(j['score_trend']),
      thresholdWithinBaseline: (rawThresholds['within_baseline'] as num?)?.toDouble() ?? 80.0,
      thresholdDeterioration: (rawThresholds['deterioration'] as num?)?.toDouble() ?? 70.0,
      thresholdSignificant: (rawThresholds['significant'] as num?)?.toDouble() ?? 60.0,
      insights: insights,
      bands: bands,
    );
  }
}

class ClinicalAlertAction {
  const ClinicalAlertAction({
    required this.id,
    required this.alertId,
    required this.actionType,
    this.otherDetails,
    this.performedAt,
  });

  final int id;
  final int alertId;
  final String actionType;
  final String? otherDetails;
  final DateTime? performedAt;

  factory ClinicalAlertAction.fromJson(Map<String, dynamic> j) {
    DateTime? dt;
    if (j['performed_at'] != null) {
      try {
        dt = DateTime.parse(j['performed_at'].toString());
      } catch (_) {}
    }
    return ClinicalAlertAction(
      id: (j['id'] as num?)?.toInt() ?? 0,
      alertId: (j['alert_id'] as num?)?.toInt() ?? 0,
      actionType: _extractString(j['action_type']) ?? 'Action Taken',
      otherDetails: _extractString(j['other_details']),
      performedAt: dt,
    );
  }
}

class ClinicalIncidentAlert {
  const ClinicalIncidentAlert({
    required this.id,
    required this.vitalType,
    required this.triggeredValue,
    required this.status,
    required this.severity,
    required this.isResolved,
    this.resolvedAt,
    this.createdAt,
    required this.actionsTaken,
  });

  final int id;
  final String vitalType;
  final String triggeredValue;
  final String status;
  final String severity;
  final bool isResolved;
  final DateTime? resolvedAt;
  final DateTime? createdAt;
  final List<ClinicalAlertAction> actionsTaken;

  factory ClinicalIncidentAlert.fromJson(Map<String, dynamic> j) {
    DateTime? resDt;
    if (j['resolved_at'] != null) {
      try {
        resDt = DateTime.parse(j['resolved_at'].toString());
      } catch (_) {}
    }

    DateTime? crtDt;
    if (j['created_at'] != null) {
      try {
        crtDt = DateTime.parse(j['created_at'].toString());
      } catch (_) {}
    }

    final rawActions = j['actions_taken'] as List<dynamic>? ?? [];
    final actions = rawActions
        .whereType<Map<String, dynamic>>()
        .map(ClinicalAlertAction.fromJson)
        .toList();

    return ClinicalIncidentAlert(
      id: (j['id'] as num?)?.toInt() ?? 0,
      vitalType: _extractString(j['vital_type']) ?? 'Alert',
      triggeredValue: j['triggered_value'] != null ? j['triggered_value'].toString() : '',
      status: _extractString(j['status']) ?? 'unknown',
      severity: _extractString(j['severity']) ?? 'critical',
      isResolved: j['is_resolved'] as bool? ?? false,
      resolvedAt: resDt,
      createdAt: crtDt,
      actionsTaken: actions,
    );
  }
}

class PatientIncidentTimeline {
  const PatientIncidentTimeline({
    required this.patientId,
    required this.page,
    required this.totalAlerts,
    required this.alerts,
  });

  final int patientId;
  final int page;
  final int totalAlerts;
  final List<ClinicalIncidentAlert> alerts;

  factory PatientIncidentTimeline.fromJson(Map<String, dynamic> j) {
    final rawAlerts = j['alerts'] as List<dynamic>? ?? [];
    final alerts = rawAlerts
        .whereType<Map<String, dynamic>>()
        .map(ClinicalIncidentAlert.fromJson)
        .toList();

    return PatientIncidentTimeline(
      patientId: (j['patient_id'] as num?)?.toInt() ?? 0,
      page: (j['page'] as num?)?.toInt() ?? 1,
      totalAlerts: (j['total_alerts'] as num?)?.toInt() ?? 0,
      alerts: alerts,
    );
  }
}

