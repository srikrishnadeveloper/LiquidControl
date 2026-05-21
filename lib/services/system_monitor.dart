import 'dart:async';
import 'dart:math' as math;

import '../models/system_data.dart';
import 'wmi_service.dart';

/// High-frequency system monitoring engine with deep analytics.
///
/// Uses [WmiService.batchRead] to poll ALL sensors in a single WMI round-trip
/// every [pollInterval]. Parses packed WMI values into [SystemSnapshot] and
/// records them in [SystemHistory] ring buffers.
///
/// Enhanced with:
/// - Thermal trend analysis (rising/falling/stable/spiking)
/// - Thermal throttle detection
/// - Session statistics (peaks, energy, events)
/// - Fan efficiency metrics (RPM per duty%)
/// - Power management tracking (AC vs battery, wattage)
/// - Thermal event logging
class SystemMonitor {
  final WmiService _wmi;

  /// How often to poll sensors.
  Duration pollInterval;

  Timer? _pollTimer;
  bool _polling = false;

  /// Current system state.
  SystemSnapshot _current = SystemSnapshot();
  SystemSnapshot get current => _current;

  /// Current battery state.
  BatterySnapshot _battery = BatterySnapshot();
  BatterySnapshot get battery => _battery;

  /// Historical sensor data (ring buffers).
  final SystemHistory history;

  /// Session statistics.
  final SessionStats sessionStats;

  /// Thermal analysis results.
  ThermalAnalysis _cpuThermal = const ThermalAnalysis();
  ThermalAnalysis _gpuThermal = const ThermalAnalysis();
  ThermalAnalysis get cpuThermal => _cpuThermal;
  ThermalAnalysis get gpuThermal => _gpuThermal;

  /// Fan efficiency metrics.
  FanEfficiency _fan1Efficiency = const FanEfficiency();
  FanEfficiency _fan2Efficiency = const FanEfficiency();
  FanEfficiency get fan1Efficiency => _fan1Efficiency;
  FanEfficiency get fan2Efficiency => _fan2Efficiency;

  /// Thermal event log (last 50 events).
  final List<ThermalEvent> _thermalEvents = [];
  List<ThermalEvent> get thermalEvents => List.unmodifiable(_thermalEvents);

  /// Thermal threshold for event detection.
  int thermalThreshold;

  /// Stream of snapshots — UI subscribes to this.
  final _snapshotController = StreamController<SystemSnapshot>.broadcast();
  Stream<SystemSnapshot> get snapshots => _snapshotController.stream;

  /// Stream of battery snapshots.
  final _batteryController = StreamController<BatterySnapshot>.broadcast();
  Stream<BatterySnapshot> get batterySnapshots => _batteryController.stream;

  /// Whether monitoring is actively running.
  bool get isRunning => _pollTimer != null && _pollTimer!.isActive;

  /// Uptime since monitoring started.
  DateTime? _startedAt;
  Duration get uptime => _startedAt != null
      ? DateTime.now().difference(_startedAt!)
      : Duration.zero;

  /// Total snapshots captured.
  int _snapshotCount = 0;
  int get snapshotCount => _snapshotCount;

  /// Battery poll counter (battery is polled every N sensor polls).
  int _pollsSinceBattery = 0;
  static const _batteryPollEvery = 10; // every 10 polls (= 5s at 500ms)

  /// For thermal event edge detection.
  bool _cpuWasAboveThreshold = false;
  bool _gpuWasAboveThreshold = false;

  /// First snapshot temps for delta calculation.
  int? _firstCpuTemp;
  int? _firstGpuTemp;

  /// WMI methods to batch-read every poll cycle.
  static const _batchMethods = [
    'Fan1Info',
    'Fan2Info',
    'GetFan12RPM',
    'GetCPUFANDuty',
    'GetVGA1FANDuty',
    'GetFANCount',
    'GetFanStatus',
    'GetCPUFANControl',
    'GetCPUPerformance',
  ];

  SystemMonitor({
    required WmiService wmi,
    this.pollInterval = const Duration(milliseconds: 500),
    int historyCapacity = 300,
    this.thermalThreshold = 85,
  })  : _wmi = wmi,
        history = SystemHistory(capacity: historyCapacity),
        sessionStats = SessionStats();

  /// Start polling.
  void start() {
    if (isRunning) return;
    _startedAt = DateTime.now();
    _doPoll(); // Immediate first poll
    _pollTimer = Timer.periodic(pollInterval, (_) => _doPoll());
  }

  /// Stop polling.
  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Change poll interval while running.
  void setPollInterval(Duration interval) {
    pollInterval = interval;
    if (isRunning) {
      stop();
      start();
    }
  }

  /// Single poll cycle: batch-read all sensors, parse, record, broadcast.
  Future<void> _doPoll() async {
    if (_polling || !_wmi.isReady) return;
    _polling = true;

    final stopwatch = Stopwatch()..start();

    try {
      // Robust compatibility fallback: only query methods that actually exist on this specific device
      final activeMethods = _batchMethods.where((m) => _wmi.availableMethods.contains(m)).toList();
      final results = await _wmi.batchRead(activeMethods);
      stopwatch.stop();

      if (results == null) {
        _polling = false;
        return;
      }

      // Parse Fan1Info: byte2=temp, byte1=duty%, byte0=maxDuty
      final fan1Raw = results['Fan1Info'] ?? 0;
      final fan1Temp = (fan1Raw >> 16) & 0xFF;
      final fan1Duty = (fan1Raw >> 8) & 0xFF;
      final fan1MaxDuty = fan1Raw & 0xFF;

      // Parse Fan2Info
      final fan2Raw = results['Fan2Info'] ?? 0;
      final fan2Temp = (fan2Raw >> 16) & 0xFF;
      final fan2Duty = (fan2Raw >> 8) & 0xFF;
      final fan2MaxDuty = fan2Raw & 0xFF;

      // Parse RPMs: upper16=fan1, lower16=fan2, RPM = raw * 16 (fix for G5 MF showing half RPM)
      final rpmRaw = results['GetFan12RPM'] ?? 0;
      final fan1RPM = ((rpmRaw >> 16) & 0xFFFF) * 16;
      final fan2RPM = (rpmRaw & 0xFFFF) * 16;

      // Fan duty raw values (0xFFFFFFFF = auto mode)
      final cpuDutyRaw = results['GetCPUFANDuty'] ?? 0;
      final gpuDutyRaw = results['GetVGA1FANDuty'] ?? 0;

      // Auto mode detection
      final autoMode = cpuDutyRaw == 0xFFFFFFFF ||
          cpuDutyRaw == 4294967295 ||
          cpuDutyRaw == -1;

      final snapshot = SystemSnapshot(
        cpuTemp: fan1Temp,
        gpuTemp: fan2Temp,
        fan1RPM: fan1RPM,
        fan2RPM: fan2RPM,
        fan1Duty: fan1Duty,
        fan2Duty: fan2Duty,
        fan1MaxDuty: fan1MaxDuty,
        fan2MaxDuty: fan2MaxDuty,
        autoMode: autoMode,
        cpuFanDutyRaw: cpuDutyRaw,
        gpuFanDutyRaw: gpuDutyRaw,
        fanStatusRaw: results['GetFanStatus'] ?? 0,
        fanCount: results['GetFANCount'] ?? 0,
        cpuFanControlRaw: results['GetCPUFANControl'] ?? 0,
        cpuPerformance: results['GetCPUPerformance'] ?? 0,
        fan1InfoRaw: fan1Raw,
        fan2InfoRaw: fan2Raw,
        fan12RPMRaw: rpmRaw,
        pollDurationMs: stopwatch.elapsedMilliseconds,
      );

      _current = snapshot;
      _snapshotCount++;
      history.record(snapshot);

      // Record first temps for delta tracking
      _firstCpuTemp ??= fan1Temp;
      _firstGpuTemp ??= fan2Temp;

      // Session statistics
      sessionStats.recordSnapshot(snapshot,
          thermalThreshold: thermalThreshold);

      // Thermal trend analysis
      _analyzeThermalTrends();

      // Fan efficiency analysis
      _analyzeFanEfficiency();

      // Thermal event detection
      _detectThermalEvents(snapshot);

      if (!_snapshotController.isClosed) {
        _snapshotController.add(snapshot);
      }

      // Battery poll (less frequent)
      _pollsSinceBattery++;
      if (_pollsSinceBattery >= _batteryPollEvery) {
        _pollsSinceBattery = 0;
        _pollBattery();
      }
    } catch (_) {
      sessionStats.totalErrors++;
      // Non-fatal; next poll will retry
    }

    _polling = false;
  }

  /// Analyze temperature trends over recent history.
  void _analyzeThermalTrends() {
    _cpuThermal = _computeThermalAnalysis(
      history.cpuTemp,
      _firstCpuTemp ?? 0,
      sessionStats.cpuThermalEvents,
      sessionStats.cpuTimeAboveThreshold,
    );
    _gpuThermal = _computeThermalAnalysis(
      history.gpuTemp,
      _firstGpuTemp ?? 0,
      sessionStats.gpuThermalEvents,
      sessionStats.gpuTimeAboveThreshold,
    );
  }

  ThermalAnalysis _computeThermalAnalysis(
    SensorHistory tempHistory,
    int firstTemp,
    int thermalEvents,
    double timeAboveThreshold,
  ) {
    if (tempHistory.length < 5) {
      return const ThermalAnalysis();
    }

    // Get last 20 samples (10 seconds at 500ms)
    final n = math.min(20, tempHistory.length);
    final samples = tempHistory.lastN(n);

    // Linear regression for rate of change
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
    for (int i = 0; i < samples.length; i++) {
      final x = i * 0.5; // seconds
      final y = samples[i];
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
    }
    final nD = samples.length.toDouble();
    final denom = nD * sumX2 - sumX * sumX;
    final ratePerSec = denom != 0 ? (nD * sumXY - sumX * sumY) / denom : 0.0;

    // Determine trend
    ThermalTrend trend;
    if (ratePerSec.abs() < 0.1) {
      trend = ThermalTrend.stable;
    } else if (ratePerSec > 1.5) {
      trend = ThermalTrend.spiking;
    } else if (ratePerSec > 0.1) {
      trend = ThermalTrend.rising;
    } else {
      trend = ThermalTrend.falling;
    }

    // Time to critical at current rate
    double? secondsToCritical;
    final currentTemp = samples.last;
    if (ratePerSec > 0.1 && currentTemp < 95) {
      secondsToCritical = (95 - currentTemp) / ratePerSec;
    }

    // Throttle detection: sustained above 90C for 5+ seconds
    final throttleLikely = _isThrottling(samples);

    final deltaFromStart = currentTemp - firstTemp;

    return ThermalAnalysis(
      trend: trend,
      ratePerSec: ratePerSec,
      secondsToCritical: secondsToCritical,
      throttleLikely: throttleLikely,
      thermalEvents: thermalEvents,
      timeAboveThreshold: timeAboveThreshold,
      deltaFromStart: deltaFromStart,
    );
  }

  bool _isThrottling(List<double> samples) {
    if (samples.length < 10) return false;
    // Check if last 10 samples (5 seconds) are all above 90C
    int countAbove90 = 0;
    for (int i = samples.length - 10; i < samples.length; i++) {
      if (samples[i] >= 90) countAbove90++;
    }
    return countAbove90 >= 8; // 80% of last 5s above 90C
  }

  /// Detect and log thermal events (edge detection).
  void _detectThermalEvents(SystemSnapshot snap) {
    final now = DateTime.now();

    // CPU threshold crossing
    if (snap.cpuTemp >= thermalThreshold && !_cpuWasAboveThreshold) {
      _cpuWasAboveThreshold = true;
      sessionStats.recordThermalEvent(true);
      _addThermalEvent(ThermalEvent(
        timestamp: now,
        sensor: 'CPU',
        temperature: snap.cpuTemp,
        type: 'threshold',
        description:
            'CPU temp crossed ${thermalThreshold}C (${snap.cpuTemp}C)',
      ));
    } else if (snap.cpuTemp < thermalThreshold - 3) {
      _cpuWasAboveThreshold = false;
    }

    // GPU threshold crossing
    if (snap.gpuTemp >= thermalThreshold && !_gpuWasAboveThreshold) {
      _gpuWasAboveThreshold = true;
      sessionStats.recordThermalEvent(false);
      _addThermalEvent(ThermalEvent(
        timestamp: now,
        sensor: 'GPU',
        temperature: snap.gpuTemp,
        type: 'threshold',
        description:
            'GPU temp crossed ${thermalThreshold}C (${snap.gpuTemp}C)',
      ));
    } else if (snap.gpuTemp < thermalThreshold - 3) {
      _gpuWasAboveThreshold = false;
    }

    // Spike detection (>5C jump in one poll)
    if (history.cpuTemp.length >= 2) {
      final prev = history.cpuTemp.valueAt(history.cpuTemp.length - 2);
      if ((snap.cpuTemp - prev).abs() > 5) {
        _addThermalEvent(ThermalEvent(
          timestamp: now,
          sensor: 'CPU',
          temperature: snap.cpuTemp,
          type: 'spike',
          description:
              'CPU spike: ${prev.toInt()}C -> ${snap.cpuTemp}C (${snap.cpuTemp - prev.toInt() > 0 ? '+' : ''}${snap.cpuTemp - prev.toInt()}C)',
        ));
      }
    }
    if (history.gpuTemp.length >= 2) {
      final prev = history.gpuTemp.valueAt(history.gpuTemp.length - 2);
      if ((snap.gpuTemp - prev).abs() > 5) {
        _addThermalEvent(ThermalEvent(
          timestamp: now,
          sensor: 'GPU',
          temperature: snap.gpuTemp,
          type: 'spike',
          description:
              'GPU spike: ${prev.toInt()}C -> ${snap.gpuTemp}C (${snap.gpuTemp - prev.toInt() > 0 ? '+' : ''}${snap.gpuTemp - prev.toInt()}C)',
        ));
      }
    }

    // Throttle detection event
    if (_cpuThermal.throttleLikely || _gpuThermal.throttleLikely) {
      // Only log once per throttle episode
      if (_thermalEvents.isEmpty ||
          _thermalEvents.last.type != 'throttle' ||
          now.difference(_thermalEvents.last.timestamp).inSeconds > 30) {
        sessionStats.throttleDetections++;
        _addThermalEvent(ThermalEvent(
          timestamp: now,
          sensor: _cpuThermal.throttleLikely ? 'CPU' : 'GPU',
          temperature: _cpuThermal.throttleLikely
              ? _current.cpuTemp
              : _current.gpuTemp,
          type: 'throttle',
          description: 'Thermal throttling detected! Sustained >90C',
        ));
      }
    }
  }

  void _addThermalEvent(ThermalEvent event) {
    _thermalEvents.add(event);
    if (_thermalEvents.length > 50) {
      _thermalEvents.removeAt(0);
    }
  }

  /// Analyze fan efficiency (RPM per duty%).
  void _analyzeFanEfficiency() {
    _fan1Efficiency = _computeFanEfficiency(
        history.fan1RPM, history.fan1Duty);
    _fan2Efficiency = _computeFanEfficiency(
        history.fan2RPM, history.fan2Duty);
  }

  FanEfficiency _computeFanEfficiency(
      SensorHistory rpmHistory, SensorHistory dutyHistory) {
    if (rpmHistory.length < 2 || dutyHistory.length < 2) {
      return const FanEfficiency();
    }

    final currentRpm = rpmHistory.latest;
    final currentDuty = dutyHistory.latest;

    // Current efficiency: RPM per 1% duty
    final rpmPerDuty =
        currentDuty > 0 ? currentRpm / currentDuty : 0.0;

    // Average over history
    double totalRpmPerDuty = 0;
    int validSamples = 0;
    final count = math.min(rpmHistory.length, dutyHistory.length);
    for (int i = 0; i < count; i++) {
      final duty = dutyHistory.valueAt(i);
      final rpm = rpmHistory.valueAt(i);
      if (duty > 5 && rpm > 0) {
        totalRpmPerDuty += rpm / duty;
        validSamples++;
      }
    }
    final avgRpmPerDuty =
        validSamples > 0 ? totalRpmPerDuty / validSamples : 0.0;

    // Estimate response time by finding how long RPM takes to settle after
    // duty changes (simplified — look at std dev of recent RPM)
    final recentRpm = rpmHistory.lastN(math.min(10, rpmHistory.length));
    double rpmStdDev = 0;
    if (recentRpm.length >= 3) {
      final avgRpm = recentRpm.reduce((a, b) => a + b) / recentRpm.length;
      double sumSq = 0;
      for (final r in recentRpm) {
        sumSq += (r - avgRpm) * (r - avgRpm);
      }
      rpmStdDev = math.sqrt(sumSq / recentRpm.length);
    }
    // High stddev = still settling, estimate ~2s. Low = stable, ~500ms.
    final estimatedResponseMs = rpmStdDev > 200 ? 2000 : rpmStdDev > 50 ? 1000 : 500;

    return FanEfficiency(
      rpmPerDutyPercent: rpmPerDuty,
      currentEfficiency: rpmPerDuty,
      avgRpmPerDuty: avgRpmPerDuty,
      estimatedResponseMs: estimatedResponseMs,
    );
  }

  /// Poll battery data (runs less frequently).
  Future<void> _pollBattery() async {
    try {
      final batMap = await _wmi.readBattery();
      if (batMap == null) return;

      _battery = BatterySnapshot.fromMap(batMap);
      history.recordBattery(_battery);
      sessionStats.recordBattery(_battery);

      if (!_batteryController.isClosed) {
        _batteryController.add(_battery);
      }
    } catch (_) {
      // Non-fatal
    }
  }

  /// Force an immediate battery poll.
  Future<void> pollBatteryNow() async {
    await _pollBattery();
  }

  /// Clear history, reset stats, clear events.
  void resetHistory() {
    history.clear();
    _snapshotCount = 0;
    _startedAt = DateTime.now();
    _firstCpuTemp = null;
    _firstGpuTemp = null;
    _cpuWasAboveThreshold = false;
    _gpuWasAboveThreshold = false;
    _thermalEvents.clear();
    sessionStats.reset();
    _cpuThermal = const ThermalAnalysis();
    _gpuThermal = const ThermalAnalysis();
    _fan1Efficiency = const FanEfficiency();
    _fan2Efficiency = const FanEfficiency();
  }

  /// Dispose: stop polling, close stream.
  void dispose() {
    stop();
    _snapshotController.close();
    _batteryController.close();
  }
}
