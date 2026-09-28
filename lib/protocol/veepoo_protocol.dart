// ── Models ──────────────────────────────────────────────────────────────────

class PersonalInfo {
  final int sex; // 0: female, 1: male
  final int age;
  final int heightCm;
  final int weightKg;
  final int stepLengthCm;

  const PersonalInfo({
    required this.sex,
    required this.age,
    required this.heightCm,
    required this.weightKg,
    required this.stepLengthCm,
  });
}

enum BleConnectionStatus { disconnected, connecting, connected }

class EcgResultData {
  final bool isSuccess;
  final int aveHeart;
  final int aveHrv;
  final int aveQt;
  final int aveResRate;
  final int diseaseResult;
  final DateTime timestamp;

  const EcgResultData({
    required this.isSuccess,
    required this.aveHeart,
    required this.aveHrv,
    required this.aveQt,
    required this.aveResRate,
    required this.diseaseResult,
    required this.timestamp,
  });
}

class EcgDiagnosisData {
  final int diseaseRisk;
  final int pressureIndex;
  final int fatigueIndex;
  final int myocarditisRisk;
  final int chdRisk;
  final int angioscleroticRisk;

  const EcgDiagnosisData({
    required this.diseaseRisk,
    required this.pressureIndex,
    required this.fatigueIndex,
    required this.myocarditisRisk,
    required this.chdRisk,
    required this.angioscleroticRisk,
  });
}

class BandState {
  final BleConnectionStatus connectionStatus;
  final int hr;
  final int spo2;
  final int respiratoryRate;
  final double tempC;
  final double tempSkin;
  final int? systolic;
  final int? diastolic;
  final int? hrv;
  final int? stress;
  final int steps;
  final double calories;
  final double distanceKm;
  final int battery;
  final bool isRemoved;
  final int totalSleepMinutes;
  final int deepSleepMinutes;
  final int lightSleepMinutes;
  final int remSleepMinutes;
  final int wakeCount;
  final int sleepQuality;
  final String? errorMessage;

  // ECG fields
  final bool isEcgMeasuring;
  final int ecgProgress;
  final bool unpassWear;
  final String? ecgStatusMessage;
  final List<int> ecgAdcPoints;
  final EcgResultData? lastEcgResult;
  final EcgDiagnosisData? lastEcgDiagnosis;

  // 24/7 Consistency & Cycle Tracking fields
  final double consistencyScore;
  final int cycleCount;
  final String activePhase;
  final String? vitalGapWarning;

  const BandState({
    this.connectionStatus = BleConnectionStatus.disconnected,
    this.hr = 0,
    this.spo2 = 0,
    this.respiratoryRate = 0,
    this.tempC = 0.0,
    this.tempSkin = 0.0,
    this.systolic,
    this.diastolic,
    this.hrv,
    this.stress,
    this.steps = 0,
    this.calories = 0.0,
    this.distanceKm = 0.0,
    this.battery = -1,
    this.isRemoved = false,
    this.totalSleepMinutes = 0,
    this.deepSleepMinutes = 0,
    this.lightSleepMinutes = 0,
    this.remSleepMinutes = 0,
    this.wakeCount = 0,
    this.sleepQuality = 0,
    this.errorMessage,
    this.isEcgMeasuring = false,
    this.ecgProgress = 0,
    this.unpassWear = false,
    this.ecgStatusMessage,
    this.ecgAdcPoints = const [],
    this.lastEcgResult,
    this.lastEcgDiagnosis,
    this.consistencyScore = 100.0,
    this.cycleCount = 0,
    this.activePhase = '',
    this.vitalGapWarning,
  });

  BandState copyWith({
    BleConnectionStatus? connectionStatus,
    int? hr,
    int? spo2,
    int? respiratoryRate,
    double? tempC,
    double? tempSkin,
    int? systolic,
    int? diastolic,
    int? hrv,
    int? stress,
    int? steps,
    double? calories,
    double? distanceKm,
    int? battery,
    bool? isRemoved,
    int? totalSleepMinutes,
    int? deepSleepMinutes,
    int? lightSleepMinutes,
    int? remSleepMinutes,
    int? wakeCount,
    int? sleepQuality,
    String? errorMessage,
    bool clearError = false,
    bool? isEcgMeasuring,
    int? ecgProgress,
    bool? unpassWear,
    String? ecgStatusMessage,
    List<int>? ecgAdcPoints,
    EcgResultData? lastEcgResult,
    EcgDiagnosisData? lastEcgDiagnosis,
    bool clearEcgAdc = false,
    double? consistencyScore,
    int? cycleCount,
    String? activePhase,
    String? vitalGapWarning,
    bool clearWarning = false,
  }) {
    return BandState(
      connectionStatus: connectionStatus ?? this.connectionStatus,
      hr: hr ?? this.hr,
      spo2: spo2 ?? this.spo2,
      respiratoryRate: respiratoryRate ?? this.respiratoryRate,
      tempC: tempC ?? this.tempC,
      tempSkin: tempSkin ?? this.tempSkin,
      systolic: systolic ?? this.systolic,
      diastolic: diastolic ?? this.diastolic,
      hrv: hrv ?? this.hrv,
      stress: stress ?? this.stress,
      steps: steps ?? this.steps,
      calories: calories ?? this.calories,
      distanceKm: distanceKm ?? this.distanceKm,
      battery: battery ?? this.battery,
      isRemoved: isRemoved ?? this.isRemoved,
      totalSleepMinutes: totalSleepMinutes ?? this.totalSleepMinutes,
      deepSleepMinutes: deepSleepMinutes ?? this.deepSleepMinutes,
      lightSleepMinutes: lightSleepMinutes ?? this.lightSleepMinutes,
      remSleepMinutes: remSleepMinutes ?? this.remSleepMinutes,
      wakeCount: wakeCount ?? this.wakeCount,
      sleepQuality: sleepQuality ?? this.sleepQuality,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isEcgMeasuring: isEcgMeasuring ?? this.isEcgMeasuring,
      ecgProgress: ecgProgress ?? this.ecgProgress,
      unpassWear: unpassWear ?? this.unpassWear,
      ecgStatusMessage: ecgStatusMessage ?? this.ecgStatusMessage,
      ecgAdcPoints: clearEcgAdc ? const [] : (ecgAdcPoints ?? this.ecgAdcPoints),
      lastEcgResult: lastEcgResult ?? this.lastEcgResult,
      lastEcgDiagnosis: lastEcgDiagnosis ?? this.lastEcgDiagnosis,
      consistencyScore: consistencyScore ?? this.consistencyScore,
      cycleCount: cycleCount ?? this.cycleCount,
      activePhase: activePhase ?? this.activePhase,
      vitalGapWarning: clearWarning ? null : (vitalGapWarning ?? this.vitalGapWarning),
    );
  }
}


