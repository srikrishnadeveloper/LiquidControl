import 'dart:math' as math;

/// Comprehensive system state snapshot from a single polling cycle.
///
/// Every field is populated from WMI reads. All temperatures in Celsius,
/// all RPMs already multiplied by 8, all duty percentages 0-100.
class SystemSnapshot {
  /// CPU temperature from Fan1Info byte2.
  final int cpuTemp;

  /// GPU temperature from Fan2Info byte2.
  final int gpuTemp;

  /// Fan 1 (CPU) speed in RPM = GetFan12RPM upper16 * 8.
  final int fan1RPM;

  /// Fan 2 (GPU) speed in RPM = GetFan12RPM lower16 * 8.
  final int fan2RPM;

  /// Fan 1 EC-calculated duty percent from Fan1Info byte1.
  final int fan1Duty;

  /// Fan 2 EC-calculated duty percent from Fan2Info byte1.
  final int fan2Duty;

  /// Fan 1 max duty from Fan1Info byte0.
  final int fan1MaxDuty;

  /// Fan 2 max duty from Fan2Info byte0.
  final int fan2MaxDuty;

  /// Whether fans are in EC auto mode (GetCPUFANDuty == 0xFFFFFFFF).
  final bool autoMode;

  /// Raw GetCPUFANDuty value (0xFFFFFFFF = auto).
  final int cpuFanDutyRaw;

  /// Raw GetVGA1FANDuty value.
  final int gpuFanDutyRaw;

  /// GetFanStatus raw value.
  final int fanStatusRaw;

  /// GetFANCount raw value.
  final int fanCount;

  /// GetCPUFANControl raw value.
  final int cpuFanControlRaw;

  /// GetCPUPerformance raw value.
  final int cpuPerformance;

  /// Raw Fan1Info packed value (for debug display).
  final int fan1InfoRaw;

  /// Raw Fan2Info packed value.
  final int fan2InfoRaw;

  /// Raw GetFan12RPM packed value.
  final int fan12RPMRaw;

  /// Timestamp of this snapshot.
  final DateTime timestamp;

  /// Polling cycle duration in milliseconds (measures WMI latency).
  final int pollDurationMs;

  SystemSnapshot({
    this.cpuTemp = 0,
    this.gpuTemp = 0,
    this.fan1RPM = 0,
    this.fan2RPM = 0,
    this.fan1Duty = 0,
    this.fan2Duty = 0,
    this.fan1MaxDuty = 0,
    this.fan2MaxDuty = 0,
    this.autoMode = true,
    this.cpuFanDutyRaw = 0,
    this.gpuFanDutyRaw = 0,
    this.fanStatusRaw = 0,
    this.fanCount = 0,
    this.cpuFanControlRaw = 0,
    this.cpuPerformance = 0,
    this.fan1InfoRaw = 0,
    this.fan2InfoRaw = 0,
    this.fan12RPMRaw = 0,
    this.pollDurationMs = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Battery data snapshot from multiple WMI classes.
class BatterySnapshot {
  // Win32_Battery
  final int estimatedChargePercent;
  final int batteryStatus; // 1=discharging, 2=AC, 3=charged, 4=low, 5=critical
  final int availability;
  final String name;
  final int chemistry; // 1=other, 2=unknown, 3=PbAcid, 4=NiCd, 5=NiMH, 6=LiIon
  final String status;

  // BatteryStatus (root\WMI)
  final bool charging;
  final bool discharging;
  final bool powerOnline;
  final bool critical;
  final int remainingCapacityMWh;
  final int voltageMV;
  final int chargeRateMW;
  final int dischargeRateMW;

  // BatteryFullChargedCapacity
  final int fullChargedCapacityMWh;

  // BatteryStaticData
  final int designedCapacityMWh;
  final String deviceName;
  final String manufactureName;
  final String serialNumber;
  final String uniqueID;
  final int technology; // 0=nonrechargeable, 1=rechargeable

  // BatteryCycleCount
  final int cycleCount;

  // Computed
  final DateTime timestamp;

  BatterySnapshot({
    this.estimatedChargePercent = 0,
    this.batteryStatus = 0,
    this.availability = 0,
    this.name = '',
    this.chemistry = 0,
    this.status = '',
    this.charging = false,
    this.discharging = false,
    this.powerOnline = false,
    this.critical = false,
    this.remainingCapacityMWh = 0,
    this.voltageMV = 0,
    this.chargeRateMW = 0,
    this.dischargeRateMW = 0,
    this.fullChargedCapacityMWh = 0,
    this.designedCapacityMWh = 0,
    this.deviceName = '',
    this.manufactureName = '',
    this.serialNumber = '',
    this.uniqueID = '',
    this.technology = 0,
    this.cycleCount = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Battery health: fullCharged / designed * 100
  double get healthPercent {
    if (designedCapacityMWh <= 0 || fullChargedCapacityMWh <= 0) return 0;
    return (fullChargedCapacityMWh / designedCapacityMWh * 100)
        .clamp(0.0, 100.0);
  }

  /// Wear level: 100 - health%
  double get wearPercent => (100.0 - healthPercent).clamp(0.0, 100.0);

  /// Capacity lost in Wh
  double get capacityLostWh =>
      ((designedCapacityMWh - fullChargedCapacityMWh) / 1000.0)
          .clamp(0.0, double.infinity);

  /// Voltage in volts
  double get voltageV => voltageMV / 1000.0;

  /// Charge rate in watts
  double get chargeRateW => chargeRateMW / 1000.0;

  /// Discharge rate in watts
  double get dischargeRateW => dischargeRateMW / 1000.0;

  /// Current power draw/charge in watts (positive = charging, negative = discharging)
  double get powerW {
    if (charging && chargeRateMW > 0) return chargeRateW;
    if (discharging && dischargeRateMW > 0) return -dischargeRateW;
    return 0;
  }

  /// Remaining capacity in Wh
  double get remainingCapacityWh => remainingCapacityMWh / 1000.0;

  /// Full charged capacity in Wh
  double get fullChargedCapacityWh => fullChargedCapacityMWh / 1000.0;

  /// Designed capacity in Wh
  double get designedCapacityWh => designedCapacityMWh / 1000.0;

  /// Chemistry as human-readable string
  String get chemistryStr {
    switch (chemistry) {
      case 1:
        return 'Other';
      case 2:
        return 'Unknown';
      case 3:
        return 'Lead Acid';
      case 4:
        return 'Nickel Cadmium';
      case 5:
        return 'Nickel Metal Hydride';
      case 6:
        return 'Lithium-ion';
      case 7:
        return 'Zinc Air';
      case 8:
        return 'Lithium Polymer';
      default:
        return 'Unknown ($chemistry)';
    }
  }

  /// Battery status as human-readable string
  String get statusStr {
    switch (batteryStatus) {
      case 1:
        return 'Discharging';
      case 2:
        return 'AC Power';
      case 3:
        return 'Fully Charged';
      case 4:
        return 'Low';
      case 5:
        return 'Critical';
      case 6:
        return 'Charging';
      case 7:
        return 'Charging & High';
      case 8:
        return 'Charging & Low';
      case 9:
        return 'Charging & Critical';
      case 10:
        return 'Undefined';
      case 11:
        return 'Partially Charged';
      default:
        return 'Unknown ($batteryStatus)';
    }
  }

  /// Power source string
  String get powerSourceStr {
    if (powerOnline) {
      if (charging) return 'AC (Charging)';
      return 'AC Power';
    }
    return 'Battery';
  }

  /// Estimated time remaining (hours) based on current discharge rate
  double? get estimatedHoursRemaining {
    if (!discharging || dischargeRateMW <= 0 || remainingCapacityMWh <= 0) {
      return null;
    }
    return remainingCapacityMWh / dischargeRateMW;
  }

  /// Estimated time to full charge (hours)
  double? get estimatedHoursToFull {
    if (!charging || chargeRateMW <= 0 || fullChargedCapacityMWh <= 0) {
      return null;
    }
    final remaining = fullChargedCapacityMWh - remainingCapacityMWh;
    if (remaining <= 0) return 0;
    return remaining / chargeRateMW;
  }

  /// Parse from WMI JSON map
  factory BatterySnapshot.fromMap(Map<String, dynamic> m) {
    return BatterySnapshot(
      estimatedChargePercent: _intVal(m, 'estimatedChargePercent'),
      batteryStatus: _intVal(m, 'batteryStatus'),
      availability: _intVal(m, 'availability'),
      name: _strVal(m, 'name'),
      chemistry: _intVal(m, 'chemistry'),
      status: _strVal(m, 'status'),
      charging: m['charging'] == true,
      discharging: m['discharging'] == true,
      powerOnline: m['powerOnline'] == true,
      critical: m['critical'] == true,
      remainingCapacityMWh: _intVal(m, 'remainingCapacityMWh'),
      voltageMV: _intVal(m, 'voltageMV'),
      chargeRateMW: _intVal(m, 'chargeRateMW'),
      dischargeRateMW: _intVal(m, 'dischargeRateMW'),
      fullChargedCapacityMWh: _intVal(m, 'fullChargedCapacityMWh'),
      designedCapacityMWh: _intVal(m, 'designedCapacityMWh'),
      deviceName: _strVal(m, 'deviceName'),
      manufactureName: _strVal(m, 'manufactureName'),
      serialNumber: _strVal(m, 'serialNumber'),
      uniqueID: _strVal(m, 'uniqueID'),
      technology: _intVal(m, 'technology'),
      cycleCount: _intVal(m, 'cycleCount'),
    );
  }

  static int _intVal(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static String _strVal(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is String) return v;
    return v?.toString() ?? '';
  }
}

/// A single fan's parsed state (extracted from SystemSnapshot for convenience).
class FanState {
  final String name;
  final int temp;
  final int rpm;
  final int duty;
  final int maxDuty;

  const FanState({
    required this.name,
    this.temp = 0,
    this.rpm = 0,
    this.duty = 0,
    this.maxDuty = 0,
  });
}

/// Ring buffer for sensor history. Fixed capacity, overwrites oldest values.
class SensorHistory {
  final int capacity;
  final List<double> _values;
  final List<DateTime> _timestamps;
  int _head = 0;
  int _count = 0;

  SensorHistory({this.capacity = 300})
      : _values = List<double>.filled(300, 0),
        _timestamps = List<DateTime>.filled(300, DateTime.now());

  /// Add a new sample.
  void add(double value) {
    _values[_head] = value;
    _timestamps[_head] = DateTime.now();
    _head = (_head + 1) % capacity;
    if (_count < capacity) _count++;
  }

  /// Number of samples stored.
  int get length => _count;

  /// Whether buffer is empty.
  bool get isEmpty => _count == 0;

  /// Get the i-th sample from oldest (0) to newest (length-1).
  double valueAt(int i) {
    if (i < 0 || i >= _count) return 0;
    final idx = (_head - _count + i + capacity) % capacity;
    return _values[idx];
  }

  /// Get timestamp of i-th sample.
  DateTime timestampAt(int i) {
    if (i < 0 || i >= _count) return DateTime.now();
    final idx = (_head - _count + i + capacity) % capacity;
    return _timestamps[idx];
  }

  /// Most recent value.
  double get latest => _count > 0 ? valueAt(_count - 1) : 0;

  /// Minimum value in buffer.
  double get min {
    if (_count == 0) return 0;
    double m = double.infinity;
    for (int i = 0; i < _count; i++) {
      final v = valueAt(i);
      if (v < m) m = v;
    }
    return m;
  }

  /// Maximum value in buffer.
  double get max {
    if (_count == 0) return 0;
    double m = double.negativeInfinity;
    for (int i = 0; i < _count; i++) {
      final v = valueAt(i);
      if (v > m) m = v;
    }
    return m;
  }

  /// Average value in buffer.
  double get average {
    if (_count == 0) return 0;
    double sum = 0;
    for (int i = 0; i < _count; i++) {
      sum += valueAt(i);
    }
    return sum / _count;
  }

  /// Standard deviation.
  double get stdDev {
    if (_count < 2) return 0;
    final avg = average;
    double sumSq = 0;
    for (int i = 0; i < _count; i++) {
      final diff = valueAt(i) - avg;
      sumSq += diff * diff;
    }
    return math.sqrt(sumSq / _count);
  }

  /// Get the last N samples as a list (newest last).
  List<double> lastN(int n) {
    final count = n.clamp(0, _count);
    return List<double>.generate(
        count, (i) => valueAt(_count - count + i));
  }

  /// Get all values as a list (oldest to newest).
  List<double> toList() {
    return List<double>.generate(_count, (i) => valueAt(i));
  }

  /// Clear all samples.
  void clear() {
    _head = 0;
    _count = 0;
  }
}

/// Complete sensor history for the entire system.
class SystemHistory {
  final SensorHistory cpuTemp;
  final SensorHistory gpuTemp;
  final SensorHistory fan1RPM;
  final SensorHistory fan2RPM;
  final SensorHistory fan1Duty;
  final SensorHistory fan2Duty;
  final SensorHistory pollLatency;
  final SensorHistory batteryPercent;
  final SensorHistory batteryVoltage;
  final SensorHistory batteryPower;
  final SensorHistory batteryChargeRate;
  final SensorHistory batteryDischargeRate;

  SystemHistory({int capacity = 300})
      : cpuTemp = SensorHistory(capacity: capacity),
        gpuTemp = SensorHistory(capacity: capacity),
        fan1RPM = SensorHistory(capacity: capacity),
        fan2RPM = SensorHistory(capacity: capacity),
        fan1Duty = SensorHistory(capacity: capacity),
        fan2Duty = SensorHistory(capacity: capacity),
        pollLatency = SensorHistory(capacity: capacity),
        batteryPercent = SensorHistory(capacity: capacity),
        batteryVoltage = SensorHistory(capacity: capacity),
        batteryPower = SensorHistory(capacity: capacity),
        batteryChargeRate = SensorHistory(capacity: capacity),
        batteryDischargeRate = SensorHistory(capacity: capacity);

  /// Record a snapshot into all histories.
  void record(SystemSnapshot snap) {
    cpuTemp.add(snap.cpuTemp.toDouble());
    gpuTemp.add(snap.gpuTemp.toDouble());
    fan1RPM.add(snap.fan1RPM.toDouble());
    fan2RPM.add(snap.fan2RPM.toDouble());
    fan1Duty.add(snap.fan1Duty.toDouble());
    fan2Duty.add(snap.fan2Duty.toDouble());
    pollLatency.add(snap.pollDurationMs.toDouble());
  }

  /// Record battery data into histories.
  void recordBattery(BatterySnapshot bat) {
    batteryPercent.add(bat.estimatedChargePercent.toDouble());
    batteryVoltage.add(bat.voltageV);
    batteryPower.add(bat.powerW);
    batteryChargeRate.add(bat.chargeRateW);
    batteryDischargeRate.add(bat.dischargeRateW);
  }

  /// Clear all histories.
  void clear() {
    cpuTemp.clear();
    gpuTemp.clear();
    fan1RPM.clear();
    fan2RPM.clear();
    fan1Duty.clear();
    fan2Duty.clear();
    pollLatency.clear();
    batteryPercent.clear();
    batteryVoltage.clear();
    batteryPower.clear();
    batteryChargeRate.clear();
    batteryDischargeRate.clear();
  }
}

/// Fan curve: a series of (temperature, duty%) points for interpolation.
class FanCurvePoint {
  final int temp;
  final int duty;
  const FanCurvePoint(this.temp, this.duty);
}

/// Named fan curve with interpolation logic.
class FanCurve {
  final String name;
  final List<FanCurvePoint> points;

  const FanCurve({required this.name, required this.points});

  /// Interpolate duty% for a given temperature.
  int dutyForTemp(int temp) {
    if (points.isEmpty) return 50;
    if (points.length == 1) return points[0].duty;

    if (temp <= points.first.temp) return points.first.duty;
    if (temp >= points.last.temp) return points.last.duty;

    for (int i = 0; i < points.length - 1; i++) {
      final lo = points[i];
      final hi = points[i + 1];
      if (temp >= lo.temp && temp <= hi.temp) {
        if (hi.temp == lo.temp) return lo.duty;
        final fraction = (temp - lo.temp) / (hi.temp - lo.temp);
        return (lo.duty + (hi.duty - lo.duty) * fraction).round();
      }
    }

    return points.last.duty;
  }
}

// ═══════════════════════════════════════════════════════════════
//  THERMAL TREND ANALYSIS
// ═══════════════════════════════════════════════════════════════

/// Direction of temperature trend over recent samples.
enum ThermalTrend { rising, falling, stable, spiking, unknown }

/// Thermal analysis result for a single sensor.
class ThermalAnalysis {
  final ThermalTrend trend;

  /// Rate of change in degrees per second (positive = rising).
  final double ratePerSec;

  /// How many seconds until critical temp at current rate (null if not rising).
  final double? secondsToCritical;

  /// Whether thermal throttling is likely (sustained high temps).
  final bool throttleLikely;

  /// Number of times temp exceeded threshold in session.
  final int thermalEvents;

  /// Time spent above threshold in seconds.
  final double timeAboveThreshold;

  /// Temperature delta from session start.
  final double deltaFromStart;

  const ThermalAnalysis({
    this.trend = ThermalTrend.unknown,
    this.ratePerSec = 0,
    this.secondsToCritical,
    this.throttleLikely = false,
    this.thermalEvents = 0,
    this.timeAboveThreshold = 0,
    this.deltaFromStart = 0,
  });
}

// ═══════════════════════════════════════════════════════════════
//  FAN EFFICIENCY METRICS
// ═══════════════════════════════════════════════════════════════

/// Fan efficiency analysis.
class FanEfficiency {
  /// RPM per 1% duty (higher = more efficient).
  final double rpmPerDutyPercent;

  /// Current operating point on the RPM vs duty curve.
  final double currentEfficiency;

  /// Average RPM response per duty step over session.
  final double avgRpmPerDuty;

  /// Fan response time: estimated ms for RPM to reach target after duty change.
  final int estimatedResponseMs;

  const FanEfficiency({
    this.rpmPerDutyPercent = 0,
    this.currentEfficiency = 0,
    this.avgRpmPerDuty = 0,
    this.estimatedResponseMs = 0,
  });
}

// ═══════════════════════════════════════════════════════════════
//  SESSION STATISTICS
// ═══════════════════════════════════════════════════════════════

/// Comprehensive session statistics tracked since monitoring started.
class SessionStats {
  final DateTime sessionStart;

  // Temperature peaks
  int cpuTempPeak;
  int gpuTempPeak;
  int cpuTempMin;
  int gpuTempMin;

  // Fan peaks
  int fan1RPMPeak;
  int fan2RPMPeak;
  int fan1DutyPeak;
  int fan2DutyPeak;

  // Thermal event tracking
  int cpuThermalEvents; // times CPU temp went above threshold
  int gpuThermalEvents;
  double cpuTimeAboveThreshold; // seconds
  double gpuTimeAboveThreshold;
  int throttleDetections;

  // Power / energy tracking
  double totalEnergyConsumedWh; // total energy drawn from battery
  double totalEnergyChargedWh; // total energy charged
  double peakDischargePowerW;
  double peakChargePowerW;
  double avgPowerDrawW;
  int powerSampleCount;
  double _powerAccumulator;

  // AC vs Battery time tracking
  double timeOnACSeconds;
  double timeOnBatterySeconds;
  bool _lastWasAC;

  // Polling stats
  int totalPolls;
  int totalErrors;
  int pollLatencyPeak;
  double pollLatencyAvg;
  double _latencyAccumulator;

  // Fan write tracking
  int totalFanWrites;
  int safetyTrips;

  SessionStats({DateTime? start})
      : sessionStart = start ?? DateTime.now(),
        cpuTempPeak = 0,
        gpuTempPeak = 0,
        cpuTempMin = 999,
        gpuTempMin = 999,
        fan1RPMPeak = 0,
        fan2RPMPeak = 0,
        fan1DutyPeak = 0,
        fan2DutyPeak = 0,
        cpuThermalEvents = 0,
        gpuThermalEvents = 0,
        cpuTimeAboveThreshold = 0,
        gpuTimeAboveThreshold = 0,
        throttleDetections = 0,
        totalEnergyConsumedWh = 0,
        totalEnergyChargedWh = 0,
        peakDischargePowerW = 0,
        peakChargePowerW = 0,
        avgPowerDrawW = 0,
        powerSampleCount = 0,
        _powerAccumulator = 0,
        timeOnACSeconds = 0,
        timeOnBatterySeconds = 0,
        _lastWasAC = true,
        totalPolls = 0,
        totalErrors = 0,
        pollLatencyPeak = 0,
        pollLatencyAvg = 0,
        _latencyAccumulator = 0,
        totalFanWrites = 0,
        safetyTrips = 0;

  Duration get sessionDuration =>
      DateTime.now().difference(sessionStart);

  /// Update with a new system snapshot.
  void recordSnapshot(SystemSnapshot snap, {int thermalThreshold = 85}) {
    totalPolls++;

    // Temperature peaks
    if (snap.cpuTemp > cpuTempPeak) cpuTempPeak = snap.cpuTemp;
    if (snap.gpuTemp > gpuTempPeak) gpuTempPeak = snap.gpuTemp;
    if (snap.cpuTemp > 0 && snap.cpuTemp < cpuTempMin) {
      cpuTempMin = snap.cpuTemp;
    }
    if (snap.gpuTemp > 0 && snap.gpuTemp < gpuTempMin) {
      gpuTempMin = snap.gpuTemp;
    }

    // Fan peaks
    if (snap.fan1RPM > fan1RPMPeak) fan1RPMPeak = snap.fan1RPM;
    if (snap.fan2RPM > fan2RPMPeak) fan2RPMPeak = snap.fan2RPM;
    if (snap.fan1Duty > fan1DutyPeak) fan1DutyPeak = snap.fan1Duty;
    if (snap.fan2Duty > fan2DutyPeak) fan2DutyPeak = snap.fan2Duty;

    // Thermal events (0.5s per poll at 500ms interval)
    if (snap.cpuTemp >= thermalThreshold) {
      cpuTimeAboveThreshold += 0.5;
    }
    if (snap.gpuTemp >= thermalThreshold) {
      gpuTimeAboveThreshold += 0.5;
    }

    // Poll latency
    if (snap.pollDurationMs > pollLatencyPeak) {
      pollLatencyPeak = snap.pollDurationMs;
    }
    _latencyAccumulator += snap.pollDurationMs;
    pollLatencyAvg = _latencyAccumulator / totalPolls;
  }

  /// Update with a new battery snapshot.
  void recordBattery(BatterySnapshot bat, {double pollIntervalSec = 5.0}) {
    // Power tracking
    final power = bat.powerW.abs();
    if (power > 0) {
      powerSampleCount++;
      _powerAccumulator += power;
      avgPowerDrawW = _powerAccumulator / powerSampleCount;
    }

    if (bat.discharging && bat.dischargeRateW > peakDischargePowerW) {
      peakDischargePowerW = bat.dischargeRateW;
    }
    if (bat.charging && bat.chargeRateW > peakChargePowerW) {
      peakChargePowerW = bat.chargeRateW;
    }

    // Energy consumed/charged (Wh = W * hours)
    final hours = pollIntervalSec / 3600.0;
    if (bat.discharging && bat.dischargeRateMW > 0) {
      totalEnergyConsumedWh += bat.dischargeRateW * hours;
    }
    if (bat.charging && bat.chargeRateMW > 0) {
      totalEnergyChargedWh += bat.chargeRateW * hours;
    }

    // AC vs battery time
    if (bat.powerOnline) {
      timeOnACSeconds += pollIntervalSec;
    } else {
      timeOnBatterySeconds += pollIntervalSec;
    }
    _lastWasAC = bat.powerOnline;
  }

  /// Increment thermal event counter.
  void recordThermalEvent(bool cpu) {
    if (cpu) {
      cpuThermalEvents++;
    } else {
      gpuThermalEvents++;
    }
  }

  void reset() {
    cpuTempPeak = 0;
    gpuTempPeak = 0;
    cpuTempMin = 999;
    gpuTempMin = 999;
    fan1RPMPeak = 0;
    fan2RPMPeak = 0;
    fan1DutyPeak = 0;
    fan2DutyPeak = 0;
    cpuThermalEvents = 0;
    gpuThermalEvents = 0;
    cpuTimeAboveThreshold = 0;
    gpuTimeAboveThreshold = 0;
    throttleDetections = 0;
    totalEnergyConsumedWh = 0;
    totalEnergyChargedWh = 0;
    peakDischargePowerW = 0;
    peakChargePowerW = 0;
    avgPowerDrawW = 0;
    powerSampleCount = 0;
    _powerAccumulator = 0;
    timeOnACSeconds = 0;
    timeOnBatterySeconds = 0;
    totalPolls = 0;
    totalErrors = 0;
    pollLatencyPeak = 0;
    pollLatencyAvg = 0;
    _latencyAccumulator = 0;
    totalFanWrites = 0;
    safetyTrips = 0;
  }
}

// ═══════════════════════════════════════════════════════════════
//  THERMAL EVENT LOG
// ═══════════════════════════════════════════════════════════════

/// A logged thermal event for the session timeline.
class ThermalEvent {
  final DateTime timestamp;
  final String sensor; // 'CPU' or 'GPU'
  final int temperature;
  final String type; // 'threshold', 'spike', 'throttle'
  final String description;

  const ThermalEvent({
    required this.timestamp,
    required this.sensor,
    required this.temperature,
    required this.type,
    required this.description,
  });
}
