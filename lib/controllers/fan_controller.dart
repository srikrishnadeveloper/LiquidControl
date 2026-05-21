import 'dart:async';

import '../models/system_data.dart';
import '../services/wmi_service.dart';
import '../services/system_monitor.dart';

/// Fan control mode.
enum FanMode {
  /// EC handles everything. No SetFanDuty calls.
  auto_,

  /// Fixed duty percent set by user. Overrides EC.
  fixed,

  /// Custom fan curve: duty% based on temperature via interpolation.
  curve,

  /// Profile-based: uses a named profile's curves.
  profile,
}

/// Fan controller: manages fan speed via WMI SetFanDuty/SetFanAutoDuty.
///
/// Safety features:
/// - Thermal throttle: if CPU or GPU exceeds [criticalTemp], immediately
///   switches to auto mode.
/// - Minimum duty: never sets duty below [minimumDuty]% in any mode.
/// - Watchdog: if no successful WMI write in [watchdogTimeout], resets to auto.
/// - Auto-reset on dispose: always returns fans to EC auto control.
/// - Hysteresis: prevents fan speed oscillation at curve inflection points.
class FanController {
  final WmiService _wmi;
  final SystemMonitor _monitor;

  FanMode _mode = FanMode.auto_;
  FanMode get mode => _mode;

  // Safety thresholds
  int criticalTemp;
  int minimumDuty;
  Duration watchdogTimeout;

  // Fixed mode
  int _fixedDuty = 50;
  int get fixedDuty => _fixedDuty;

  // Curve mode
  FanCurve _cpuCurve;
  FanCurve _gpuCurve;
  FanCurve get cpuCurve => _cpuCurve;
  FanCurve get gpuCurve => _gpuCurve;

  // Hysteresis: only change duty if delta exceeds this threshold
  int hysteresis;
  int _lastAppliedDuty = -1;
  int get lastAppliedDuty => _lastAppliedDuty;

  // Watchdog
  DateTime _lastSuccessfulWrite = DateTime.now();
  Timer? _watchdogTimer;

  // Control loop
  StreamSubscription<SystemSnapshot>? _monitorSub;
  Timer? _controlTimer;
  static const _controlInterval = Duration(milliseconds: 1000);

  // Status
  bool _safetyTripped = false;
  bool get safetyTripped => _safetyTripped;
  String _statusMessage = 'Idle';
  String get statusMessage => _statusMessage;
  int _writeCount = 0;
  int get writeCount => _writeCount;

  // Target duty (what we're aiming for — for UI display)
  int _targetDuty = 0;
  int get targetDuty => _targetDuty;

  // Performance mode currently set
  int _performanceMode = 0;
  int get performanceMode => _performanceMode;

  /// Default fan curves.
  static const _defaultCpuCurve = FanCurve(
    name: 'Default CPU',
    points: [
      FanCurvePoint(30, 25),
      FanCurvePoint(45, 30),
      FanCurvePoint(55, 40),
      FanCurvePoint(65, 55),
      FanCurvePoint(75, 70),
      FanCurvePoint(85, 90),
      FanCurvePoint(95, 100),
    ],
  );

  static const _defaultGpuCurve = FanCurve(
    name: 'Default GPU',
    points: [
      FanCurvePoint(30, 25),
      FanCurvePoint(45, 30),
      FanCurvePoint(55, 40),
      FanCurvePoint(65, 55),
      FanCurvePoint(75, 75),
      FanCurvePoint(85, 95),
      FanCurvePoint(90, 100),
    ],
  );

  FanController({
    required WmiService wmi,
    required SystemMonitor monitor,
    this.criticalTemp = 95,
    this.minimumDuty = 20,
    this.hysteresis = 3,
    this.watchdogTimeout = const Duration(seconds: 30),
    FanCurve? cpuCurve,
    FanCurve? gpuCurve,
  })  : _wmi = wmi,
        _monitor = monitor,
        _cpuCurve = cpuCurve ?? _defaultCpuCurve,
        _gpuCurve = gpuCurve ?? _defaultGpuCurve;

  /// Start the control loop. Listens to monitor snapshots and adjusts fans.
  void start() {
    _monitorSub?.cancel();
    _controlTimer?.cancel();

    // Control loop runs every second
    _controlTimer = Timer.periodic(_controlInterval, (_) => _controlCycle());

    // Watchdog checks every 10 seconds
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _watchdogCheck(),
    );

    _statusMessage = 'Running (${_mode.name})';
  }

  /// Stop the control loop (does NOT reset to auto — call resetToAuto for that).
  void stop() {
    _monitorSub?.cancel();
    _monitorSub = null;
    _controlTimer?.cancel();
    _controlTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _statusMessage = 'Stopped';
  }

  /// Switch to auto mode (EC controls fans).
  Future<void> setAutoMode() async {
    _mode = FanMode.auto_;
    _lastAppliedDuty = -1;
    _targetDuty = 0;
    await _resetToAuto();
    _statusMessage = 'Auto mode (EC controlled)';
  }

  /// Switch to fixed duty mode with exact percentage.
  Future<void> setFixedDuty(int duty) async {
    _fixedDuty = duty.clamp(minimumDuty, 100);
    _targetDuty = _fixedDuty;
    _mode = FanMode.fixed;
    _lastAppliedDuty = -1; // Force re-apply
    _statusMessage = 'Fixed duty: $_fixedDuty%';
  }

  /// Set exact duty percentage — precision control from number input.
  Future<void> setExactDuty(int duty) async {
    await setFixedDuty(duty);
  }

  /// Step duty up by [step] percent.
  Future<void> stepDutyUp({int step = 5}) async {
    final newDuty = (_fixedDuty + step).clamp(minimumDuty, 100);
    await setFixedDuty(newDuty);
  }

  /// Step duty down by [step] percent.
  Future<void> stepDutyDown({int step = 5}) async {
    final newDuty = (_fixedDuty - step).clamp(minimumDuty, 100);
    await setFixedDuty(newDuty);
  }

  /// Set CPU performance mode (0/1/2) via SetCPUPerformance.
  Future<bool> setPerformanceMode(int mode) async {
    final clamped = mode.clamp(0, 2);
    final ok = await _wmi.write('SetCPUPerformance', clamped);
    if (ok) {
      _performanceMode = clamped;
    }
    return ok;
  }

  /// Switch to custom curve mode.
  void setCurveMode({FanCurve? cpuCurve, FanCurve? gpuCurve}) {
    if (cpuCurve != null) _cpuCurve = cpuCurve;
    if (gpuCurve != null) _gpuCurve = gpuCurve;
    _mode = FanMode.curve;
    _lastAppliedDuty = -1;
    _statusMessage = 'Curve mode';
  }

  /// Apply a performance profile.
  void applyProfile(PerformanceProfile profile) {
    _cpuCurve = profile.cpuCurve;
    _gpuCurve = profile.gpuCurve;
    _mode = FanMode.profile;
    _lastAppliedDuty = -1;
    _statusMessage = 'Profile: ${profile.name}';

    // Also set CPU performance mode if defined in profile
    if (profile.cpuPerformanceMode != null) {
      setPerformanceMode(profile.cpuPerformanceMode!);
    }
  }

  /// Core control cycle — called every second.
  Future<void> _controlCycle() async {
    if (!_wmi.isReady) return;
    final snap = _monitor.current;

    // SAFETY CHECK: critical temperature override
    if (snap.cpuTemp >= criticalTemp || snap.gpuTemp >= criticalTemp) {
      if (!_safetyTripped) {
        _safetyTripped = true;
        _monitor.sessionStats.safetyTrips++;
        _statusMessage = 'CRITICAL TEMP! Resetting to auto. '
            'CPU:${snap.cpuTemp}C GPU:${snap.gpuTemp}C';
        await _resetToAuto();
      }
      return;
    }

    // Clear safety trip if temps are back to normal
    if (_safetyTripped && snap.cpuTemp < criticalTemp - 5 && snap.gpuTemp < criticalTemp - 5) {
      _safetyTripped = false;
      _statusMessage = 'Temps normal, resuming control';
    }

    // Apply control based on mode
    switch (_mode) {
      case FanMode.auto_:
        // Nothing to do — EC controls fans
        break;

      case FanMode.fixed:
        await _applyDuty(_fixedDuty);
        break;

      case FanMode.curve:
      case FanMode.profile:
        // Get target duty from curves based on current temperatures
        final cpuTarget = _cpuCurve.dutyForTemp(snap.cpuTemp);
        final gpuTarget = _gpuCurve.dutyForTemp(snap.gpuTemp);
        // Use the higher of the two targets (don't starve either component)
        _targetDuty = cpuTarget > gpuTarget ? cpuTarget : gpuTarget;
        await _applyDuty(_targetDuty);
        break;
    }
  }

  /// Apply a duty percentage via SetFanDuty, with hysteresis and minimum.
  Future<void> _applyDuty(int duty) async {
    duty = duty.clamp(minimumDuty, 100);
    _targetDuty = duty;

    // Hysteresis: skip if change is too small
    if (_lastAppliedDuty >= 0 &&
        (duty - _lastAppliedDuty).abs() < hysteresis) {
      return;
    }

    // Ensure EC is in MANUAL mode before writing the duty (SetFanAutoDuty: 1 = Manual, 0 = Auto)
    if (_lastAppliedDuty < 0) {
      await _wmi.write('SetFanAutoDuty', 1);
    }

    final ok = await _wmi.write('SetFanDuty', duty);
    if (ok) {
      _lastAppliedDuty = duty;
      _lastSuccessfulWrite = DateTime.now();
      _writeCount++;
      _monitor.sessionStats.totalFanWrites++;
      if (_mode == FanMode.fixed) {
        _statusMessage = 'Fixed: $duty%';
      } else {
        _statusMessage = '${_mode.name}: $duty% applied';
      }
    }
  }

  /// Reset fans to EC auto control via SetFanAutoDuty.
  Future<bool> _resetToAuto() async {
    final ok = await _wmi.write('SetFanAutoDuty', 0);
    if (ok) {
      _lastAppliedDuty = -1;
      _targetDuty = 0;
      _lastSuccessfulWrite = DateTime.now();
    }
    return ok;
  }

  /// Watchdog: if no successful write in [watchdogTimeout], reset to auto.
  void _watchdogCheck() {
    if (_mode == FanMode.auto_) return;
    final elapsed = DateTime.now().difference(_lastSuccessfulWrite);
    if (elapsed > watchdogTimeout) {
      _statusMessage = 'Watchdog: no writes for ${elapsed.inSeconds}s, resetting to auto';
      _resetToAuto();
      _mode = FanMode.auto_;
    }
  }

  /// Public: force reset to auto.
  Future<void> resetToAuto() async {
    _mode = FanMode.auto_;
    _lastAppliedDuty = -1;
    _targetDuty = 0;
    _safetyTripped = false;
    await _resetToAuto();
    _statusMessage = 'Auto mode (EC controlled)';
  }

  /// Dispose: stop control loop, reset to auto.
  Future<void> dispose() async {
    stop();
    // Safety: always reset to auto on exit
    if (_wmi.isReady) {
      await _resetToAuto();
    }
  }
}

/// Performance profile: a named set of fan curves + settings.
class PerformanceProfile {
  final String name;
  final String description;
  final FanCurve cpuCurve;
  final FanCurve gpuCurve;
  final int? cpuPerformanceMode; // SetCPUPerformance value (0/1/2)

  const PerformanceProfile({
    required this.name,
    required this.description,
    required this.cpuCurve,
    required this.gpuCurve,
    this.cpuPerformanceMode,
  });
}

/// Predefined profiles.
class Profiles {
  Profiles._();

  static const silent = PerformanceProfile(
    name: 'Silent',
    description: 'Minimal noise. Fans run as slow as possible.',
    cpuPerformanceMode: 0,
    cpuCurve: FanCurve(name: 'Silent CPU', points: [
      FanCurvePoint(30, 20),
      FanCurvePoint(50, 25),
      FanCurvePoint(60, 30),
      FanCurvePoint(70, 40),
      FanCurvePoint(80, 55),
      FanCurvePoint(90, 80),
      FanCurvePoint(95, 100),
    ]),
    gpuCurve: FanCurve(name: 'Silent GPU', points: [
      FanCurvePoint(30, 20),
      FanCurvePoint(50, 25),
      FanCurvePoint(60, 30),
      FanCurvePoint(70, 45),
      FanCurvePoint(80, 60),
      FanCurvePoint(85, 80),
      FanCurvePoint(90, 100),
    ]),
  );

  static const balanced = PerformanceProfile(
    name: 'Balanced',
    description: 'Good balance between noise and thermals.',
    cpuPerformanceMode: 0,
    cpuCurve: FanCurve(name: 'Balanced CPU', points: [
      FanCurvePoint(30, 25),
      FanCurvePoint(45, 30),
      FanCurvePoint(55, 40),
      FanCurvePoint(65, 55),
      FanCurvePoint(75, 70),
      FanCurvePoint(85, 90),
      FanCurvePoint(95, 100),
    ]),
    gpuCurve: FanCurve(name: 'Balanced GPU', points: [
      FanCurvePoint(30, 25),
      FanCurvePoint(45, 30),
      FanCurvePoint(55, 40),
      FanCurvePoint(65, 55),
      FanCurvePoint(75, 75),
      FanCurvePoint(85, 95),
      FanCurvePoint(90, 100),
    ]),
  );

  static const performance = PerformanceProfile(
    name: 'Performance',
    description: 'Aggressive cooling for sustained workloads.',
    cpuPerformanceMode: 1,
    cpuCurve: FanCurve(name: 'Perf CPU', points: [
      FanCurvePoint(30, 35),
      FanCurvePoint(45, 45),
      FanCurvePoint(55, 60),
      FanCurvePoint(65, 75),
      FanCurvePoint(75, 90),
      FanCurvePoint(80, 100),
    ]),
    gpuCurve: FanCurve(name: 'Perf GPU', points: [
      FanCurvePoint(30, 35),
      FanCurvePoint(45, 45),
      FanCurvePoint(55, 60),
      FanCurvePoint(65, 80),
      FanCurvePoint(75, 95),
      FanCurvePoint(80, 100),
    ]),
  );

  static const beast = PerformanceProfile(
    name: 'Beast',
    description: 'Maximum cooling. All fans at full speed.',
    cpuPerformanceMode: 2,
    cpuCurve: FanCurve(name: 'Beast CPU', points: [
      FanCurvePoint(0, 100),
    ]),
    gpuCurve: FanCurve(name: 'Beast GPU', points: [
      FanCurvePoint(0, 100),
    ]),
  );

  static const all = [silent, balanced, performance, beast];
}
