import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'models/system_data.dart';
import 'services/wmi_service.dart';
import 'services/system_monitor.dart';
import 'controllers/fan_controller.dart';

void main() {
  runApp(const LiquidControlApp());
}

class LiquidControlApp extends StatelessWidget {
  const LiquidControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liquid Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A12),
        textTheme: GoogleFonts.sairaTextTheme(ThemeData.dark().textTheme),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  final WmiService _wmi = WmiService();
  late SystemMonitor _monitor;
  late FanController _fanCtrl;
  late TabController _tabCtrl;

  bool _initializing = true;
  bool _wmiAvailable = false;
  SystemSnapshot _snap = SystemSnapshot();
  BatterySnapshot _bat = BatterySnapshot();

  // UI state
  int? _draggedCurveIndex; // null = none, 0 = CPU, 1 = GPU
  int? _draggedPointIndex; // null = none, 0 to 3

  // Custom curve editor state (exactly 4 points: start, 2 middle, end)
  List<FanCurvePoint> _customCpuPoints = [
    const FanCurvePoint(30, 25),
    const FanCurvePoint(55, 45),
    const FanCurvePoint(75, 75),
    const FanCurvePoint(100, 100),
  ];

  List<FanCurvePoint> _customGpuPoints = [
    const FanCurvePoint(30, 25),
    const FanCurvePoint(55, 45),
    const FanCurvePoint(75, 75),
    const FanCurvePoint(100, 100),
  ];

  // Debug log
  final List<String> _debugLog = [];

  // Keyboard RGB state variables
  bool _rgbRunning = false;
  Timer? _rgbTimer;
  String _rgbEffect = 'Static';
  double _rgbSpeed = 1.0;
  double _rgbBright = 255;
  double _rgbR = 255;
  double _rgbG = 0;
  double _rgbB = 0;
  Color _rgbPreviewColor = const Color(0xFFFF0000);
  DateTime _rgbStartTime = DateTime.now();
  int _rgbTickCount = 0;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 5, vsync: this);
    _monitor = SystemMonitor(wmi: _wmi);
    _fanCtrl = FanController(wmi: _wmi, monitor: _monitor);
    _init();
  }

  Future<void> _init() async {
    final ok = await _wmi.initialize();
    if (mounted) {
      setState(() {
        _wmiAvailable = ok;
        _initializing = false;
      });
    }
    if (ok) {
      _monitor.snapshots.listen((snap) {
        if (mounted) setState(() => _snap = snap);
      });
      _monitor.batterySnapshots.listen((bat) {
        if (mounted) setState(() => _bat = bat);
      });
      _monitor.start();
      _fanCtrl.start();
      _monitor.pollBatteryNow();
      
      // Initialize keyboard RGB brightness to default
      _applyKeyboardBrightness(_rgbBright.round());
      _startRgbEffect('Static');
    }
  }

  @override
  void dispose() {
    _stopRgbEffect();
    _tabCtrl.dispose();
    _fanCtrl.dispose();
    _monitor.dispose();
    _wmi.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : !_wmiAvailable
              ? _buildError()
              : _buildDashboard(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 16),
          Text('WMI Not Available', style: _headerStyle),
          const SizedBox(height: 8),
          Text(_wmi.lastError, style: _mutedStyle),
          const SizedBox(height: 8),
          Text('Run as Administrator', style: _mutedStyle),
        ],
      ),
    );
  }

  Widget _buildDashboard() {
    return Column(
      children: [
        // Header bar
        _buildHeader(),
        // Tab bar
        Container(
          color: Colors.white.withValues(alpha: 0.03),
          child: TabBar(
            controller: _tabCtrl,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white38,
            indicatorColor: const Color(0xFF44DDFF),
            labelStyle: GoogleFonts.saira(fontSize: 11, fontWeight: FontWeight.w600),
            tabs: const [
              Tab(text: 'OVERVIEW'),
              Tab(text: 'FAN CONTROL'),
              Tab(text: 'KEYBOARD RGB'),
              Tab(text: 'SYSTEM INSIGHTS'),
              Tab(text: 'BATTERY & POWER'),
            ],
          ),
        ),
        // Tab content
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            children: [
              _buildOverviewTab(),
              _buildFanControlTab(),
              _buildKeyboardRgbTab(),
              _buildInsightsTab(),
              _buildBatteryTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  HEADER
  // ═══════════════════════════════════════════════════════════════

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Colors.white.withValues(alpha: 0.02),
      child: Row(
        children: [
          Text('LIQUID CONTROL', style: _titleStyle),
          const Spacer(),
          // Quick stats in header
          _headerStat('CPU', '${_snap.cpuTemp}C', _tempColor(_snap.cpuTemp)),
          const SizedBox(width: 12),
          _headerStat('GPU', '${_snap.gpuTemp}C', _tempColor(_snap.gpuTemp)),
          const SizedBox(width: 12),
          _headerStat('F1', '${_snap.fan1RPM}', const Color(0xFF44DDFF)),
          const SizedBox(width: 12),
          _headerStat('F2', '${_snap.fan2RPM}', const Color(0xFF44DDFF)),
          const SizedBox(width: 12),
          _headerStat('BAT', '${_bat.estimatedChargePercent}%',
              _batteryColor(_bat.estimatedChargePercent, _bat.charging)),
          const SizedBox(width: 16),
          Text(
            '${_formatDuration(_monitor.uptime)} | '
            'Polls:${_monitor.snapshotCount} | '
            '${_snap.pollDurationMs}ms',
            style: _tinyStyle,
          ),
        ],
      ),
    );
  }

  Widget _headerStat(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: TextStyle(
            color: color, fontSize: 13, fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()])),
        Text(label, style: _tinyStyle.copyWith(fontSize: 8)),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TAB 1: OVERVIEW
  // ═══════════════════════════════════════════════════════════════

  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // TEMPERATURES
          Text('TEMPERATURES', style: _sectionStyle),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _tempCard('CPU', _snap.cpuTemp,
                  _monitor.history.cpuTemp, _monitor.cpuThermal)),
              const SizedBox(width: 12),
              Expanded(child: _tempCard('GPU', _snap.gpuTemp,
                  _monitor.history.gpuTemp, _monitor.gpuThermal)),
            ],
          ),
          const SizedBox(height: 16),

          // FAN SPEEDS
          Text('FAN SPEEDS', style: _sectionStyle),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _fanCard('FAN 1 (CPU)', _snap.fan1RPM,
                  _snap.fan1Duty, _snap.fan1MaxDuty,
                  _monitor.history.fan1RPM, _monitor.history.fan1Duty,
                  _monitor.fan1Efficiency)),
              const SizedBox(width: 12),
              Expanded(child: _fanCard('FAN 2 (GPU)', _snap.fan2RPM,
                  _snap.fan2Duty, _snap.fan2MaxDuty,
                  _monitor.history.fan2RPM, _monitor.history.fan2Duty,
                  _monitor.fan2Efficiency)),
            ],
          ),
          const SizedBox(height: 16),

          // QUICK BATTERY
          Text('BATTERY', style: _sectionStyle),
          const SizedBox(height: 8),
          _batteryQuickPanel(),
          const SizedBox(height: 16),

          // SESSION STATS SUMMARY
          Text('SESSION STATS', style: _sectionStyle),
          const SizedBox(height: 8),
          _sessionStatsSummary(),
          const SizedBox(height: 16),

          // HISTORY GRAPHS
          Text('HISTORY', style: _sectionStyle),
          const SizedBox(height: 8),
          _historySection(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TAB 2: FAN CONTROL
  // ═══════════════════════════════════════════════════════════════

  Widget _buildFanControlTab() {
    final isAuto = _fanCtrl.mode == FanMode.auto_;
    final isMax = _fanCtrl.mode == FanMode.fixed && _fanCtrl.fixedDuty == 100;
    final isCurve = _fanCtrl.mode == FanMode.curve;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // SPACIOUS INTERACTIVE GRAPH BOX
          Text('DRAG & DROP FAN SPEED GRAPH', style: _sectionStyle),
          const SizedBox(height: 8),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.circle, size: 10, color: Color(0xFF66FF88)),
                        const SizedBox(width: 6),
                        Text('CPU: ${_snap.cpuTemp}°C | ${_snap.fan1RPM} RPM', style: _monoStyle.copyWith(fontSize: 11)),
                      ],
                    ),
                    Row(
                      children: [
                        const Icon(Icons.gps_fixed, size: 10, color: Color(0xFFFF9933)),
                        const SizedBox(width: 6),
                        Text('GPU: ${_snap.gpuTemp}°C | ${_snap.fan2RPM} RPM', style: _monoStyle.copyWith(fontSize: 11)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                
                // Interactive Graph Canvas (Height increased to 280px for ultimate precision)
                SizedBox(
                  height: 280,
                  width: double.infinity,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final height = constraints.maxHeight;

                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (details) {
                          final localPos = details.localPosition;
                          double closestDistance = 25.0; // Hit-test radius of 25 pixels
                          int? bestCurveIndex;
                          int? closestPointIndex;

                          // Helper to check curve points
                          void checkCurve(List<FanCurvePoint> points, int curveIndex) {
                            for (int i = 0; i < points.length; i++) {
                              final pt = points[i];
                              final screenX = ((pt.temp - 30) / 70.0) * width;
                              final screenY = (1.0 - (pt.duty / 100.0)) * height;
                              final dx = localPos.dx - screenX;
                              final dy = localPos.dy - screenY;
                              final dist = math.sqrt(dx * dx + dy * dy);
                              if (dist < closestDistance) {
                                closestDistance = dist;
                                bestCurveIndex = curveIndex;
                                closestPointIndex = i;
                              }
                            }
                          }

                          checkCurve(_customCpuPoints, 0);
                          checkCurve(_customGpuPoints, 1);

                          if (bestCurveIndex != null && closestPointIndex != null) {
                            setState(() {
                              _draggedCurveIndex = bestCurveIndex;
                              _draggedPointIndex = closestPointIndex;
                            });
                          }
                        },
                        onPanUpdate: (details) {
                          if (_draggedCurveIndex == null || _draggedPointIndex == null) return;
                          
                          final localPos = details.localPosition;
                          final pctX = (localPos.dx / width).clamp(0.0, 1.0);
                          final pctY = (localPos.dy / height).clamp(0.0, 1.0);

                          final newTemp = (30 + pctX * 70).round();
                          final newDuty = ((1.0 - pctY) * 100).round();

                          final points = _draggedCurveIndex == 0 ? _customCpuPoints : _customGpuPoints;
                          final idx = _draggedPointIndex!;

                          setState(() {
                            if (idx == 0) {
                              // Start point: fixed temp (30), draggable duty
                              points[0] = FanCurvePoint(30, newDuty);
                            } else if (idx == 3) {
                              // End point: fixed temp (100), draggable duty
                              points[idx] = FanCurvePoint(100, newDuty);
                            } else {
                              // Middle points: draggable temp and duty
                              final minT = points[idx - 1].temp + 2;
                              final maxT = points[idx + 1].temp - 2;
                              final clampedTemp = newTemp.clamp(minT, maxT);
                              points[idx] = FanCurvePoint(clampedTemp, newDuty);
                            }
                          });

                          // Live feedback to the hardware if curve mode is active
                          if (_fanCtrl.mode == FanMode.curve) {
                            _applyActiveCurves();
                          }
                        },
                        onPanEnd: (details) {
                          if (_draggedCurveIndex != null && _draggedPointIndex != null) {
                            setState(() {
                              _draggedCurveIndex = null;
                              _draggedPointIndex = null;
                            });
                            _applyActiveCurves();
                          }
                        },
                        onPanCancel: () {
                          if (_draggedCurveIndex != null && _draggedPointIndex != null) {
                            setState(() {
                              _draggedCurveIndex = null;
                              _draggedPointIndex = null;
                            });
                            _applyActiveCurves();
                          }
                        },
                        child: CustomPaint(
                          painter: _CurvePainter(
                            cpuPoints: _customCpuPoints,
                            gpuPoints: _customGpuPoints,
                            selectedFanTab: _draggedCurveIndex ?? -1,
                            selectedNodeIndex: _draggedPointIndex ?? -1,
                            cpuTemp: _snap.cpuTemp,
                            gpuTemp: _snap.gpuTemp,
                          ),
                          size: Size.infinite,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Instructions: Simply touch or click on any point on the Green (CPU) or Orange (GPU) curve lines and drag them up/down/left/right to customize speeds!',
                  style: _tinyStyle.copyWith(fontStyle: FontStyle.italic, color: Colors.white54),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // PRESET COOLING MODES (Automatic, Maximum, Custom Curve)
          Text('COOLING PRESETS', style: _sectionStyle),
          const SizedBox(height: 8),
          _card(
            child: Column(
              children: [
                Row(
                  children: [
                    _presetModeButton('Automatic Mode', isAuto, () async {
                      await _fanCtrl.setAutoMode();
                      setState(() {});
                    }),
                    const SizedBox(width: 10),
                    _presetModeButton('Full Maximum Speed', isMax, () async {
                      await _fanCtrl.setFixedDuty(100);
                      setState(() {});
                    }),
                    const SizedBox(width: 10),
                    _presetModeButton('Apply Custom Curve', isCurve, () {
                      _applyActiveCurves();
                    }),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TAB 3: SYSTEM INSIGHTS
  // ═══════════════════════════════════════════════════════════════

  Widget _buildInsightsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // FAN EFFICIENCY
          Text('FAN EFFICIENCY', style: _sectionStyle),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _fanEfficiencyCard('FAN 1 (CPU)',
                  _monitor.fan1Efficiency, _snap.fan1RPM, _snap.fan1Duty)),
              const SizedBox(width: 12),
              Expanded(child: _fanEfficiencyCard('FAN 2 (GPU)',
                  _monitor.fan2Efficiency, _snap.fan2RPM, _snap.fan2Duty)),
            ],
          ),
          const SizedBox(height: 16),

          // SESSION STATISTICS (detailed)
          Text('SESSION STATISTICS', style: _sectionStyle),
          const SizedBox(height: 8),
          _sessionStatsDetailed(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TAB 4: BATTERY & POWER
  // ═══════════════════════════════════════════════════════════════

  Widget _buildBatteryTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // BATTERY STATUS
          Text('BATTERY STATUS', style: _sectionStyle),
          const SizedBox(height: 8),
          _batteryFullPanel(),
          const SizedBox(height: 16),

          // BATTERY HEALTH & WEAR
          Text('BATTERY HEALTH & WEAR ANALYSIS', style: _sectionStyle),
          const SizedBox(height: 8),
          _batteryHealthPanel(),
          const SizedBox(height: 16),

          // POWER MANAGEMENT
          Text('POWER MANAGEMENT', style: _sectionStyle),
          const SizedBox(height: 8),
          _powerManagementPanel(),
          const SizedBox(height: 16),

          // ENERGY TRACKING
          Text('ENERGY TRACKING', style: _sectionStyle),
          const SizedBox(height: 8),
          _energyTrackingPanel(),
          const SizedBox(height: 16),

          // BATTERY HISTORY GRAPHS
          Text('BATTERY HISTORY', style: _sectionStyle),
          const SizedBox(height: 8),
          _batteryHistorySection(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TAB 3: KEYBOARD RGB (combined from LiquidRGB)
  // ═══════════════════════════════════════════════════════════════

  Widget _buildKeyboardRgbTab() {
    final active = _rgbRunning && _rgbEffect != 'None';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left Column: Lighting Effects Grid (2-column layout)
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('LIGHTING EFFECTS', style: _sectionStyle),
                    const SizedBox(height: 8),
                    _card(
                      child: GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 2,
                        childAspectRatio: 3.2,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        children: [
                          _effectButton('Static', Icons.color_lens_outlined),
                          _effectButton('Breathing', Icons.favorite_border_outlined),
                          _effectButton('Rainbow', Icons.looks_outlined),
                          _effectButton('ColorCycle', Icons.sync_outlined),
                          _effectButton('Strobe', Icons.flash_on_outlined),
                          _effectButton('Candle', Icons.fireplace_outlined),
                          _effectButton('Police', Icons.local_police_outlined),
                          _effectButton('NeonPulse', Icons.bolt_outlined),
                          _effectButton('Sunset', Icons.wb_twilight_outlined),
                          _effectButton('Ocean', Icons.water_outlined),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              
              // Right Column: Backlight & Color Configuration Controls
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('COLOR CONFIGURATION', style: _sectionStyle),
                    const SizedBox(height: 8),
                    // Active State Banner
                    _card(
                      child: Row(
                        children: [
                          // Glow color swatch
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _rgbPreviewColor,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white24, width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: _rgbPreviewColor.withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  active ? 'EFFECT: ${_rgbEffect.toUpperCase()}' : 'KEYBOARD LED OFF',
                                  style: _headerStyle.copyWith(
                                    color: active ? const Color(0xFF44DDFF) : Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'R: ${_rgbR.round()} | G: ${_rgbG.round()} | B: ${_rgbB.round()}',
                                  style: _tinyStyle,
                                ),
                              ],
                            ),
                          ),
                          // STOP Button
                          GestureDetector(
                            onTap: () {
                              _stopRgbEffect();
                              _applyKeyboardColor(const Color(0xFF000000));
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                              ),
                              child: Text(
                                'STOP',
                                style: _labelStyle.copyWith(
                                  color: Colors.redAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Color Mixer card
                    _card(
                      child: Column(
                        children: [
                          _rgbSliderRow('Red', _rgbR, Colors.redAccent, (v) {
                            setState(() {
                              _rgbR = v;
                              _rgbPreviewColor = Color.fromARGB(255, _rgbR.round(), _rgbG.round(), _rgbB.round());
                            });
                            _startRgbEffect('Static');
                          }),
                          _rgbSliderRow('Green', _rgbG, Colors.greenAccent, (v) {
                            setState(() {
                              _rgbG = v;
                              _rgbPreviewColor = Color.fromARGB(255, _rgbR.round(), _rgbG.round(), _rgbB.round());
                            });
                            _startRgbEffect('Static');
                          }),
                          _rgbSliderRow('Blue', _rgbB, Colors.blueAccent, (v) {
                            setState(() {
                              _rgbB = v;
                              _rgbPreviewColor = Color.fromARGB(255, _rgbR.round(), _rgbG.round(), _rgbB.round());
                            });
                            _startRgbEffect('Static');
                          }),
                          const Divider(height: 16, color: Colors.white12),
                          _rgbSliderRow('Bright', _rgbBright, Colors.amberAccent, (v) {
                            setState(() {
                              _rgbBright = v;
                            });
                            _applyKeyboardBrightness(v.round());
                          }, min: 10, max: 255, valueSuffix: (val) => '${(val / 255 * 100).round()}%'),
                          _rgbSliderRow('Speed', _rgbSpeed, const Color(0xFF44DDFF), (v) {
                            setState(() {
                              _rgbSpeed = v;
                            });
                          }, min: 0.2, max: 4.0, divisions: 19, valueSuffix: (val) => '${val.toStringAsFixed(1)}x'),
                          const Divider(height: 16, color: Colors.white12),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text('PRESET COLORS', style: _tinyStyle.copyWith(fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _presetChip(const Color(0xFFFF0000), 'Red'),
                              _presetChip(const Color(0xFFFF7F00), 'Orange'),
                              _presetChip(const Color(0xFFFFFF00), 'Yellow'),
                              _presetChip(const Color(0xFF00FF00), 'Green'),
                              _presetChip(const Color(0xFF00FFFF), 'Cyan'),
                              _presetChip(const Color(0xFF0000FF), 'Blue'),
                              _presetChip(const Color(0xFF7F00FF), 'Purple'),
                              _presetChip(const Color(0xFFFF00FF), 'Magenta'),
                              _presetChip(const Color(0xFFFFFFFF), 'White'),
                              _presetChip(const Color(0xFF000000), 'Off'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  TEMPERATURE CARDS (enhanced with thermal trend)
  // ═══════════════════════════════════════════════════════════════

  Widget _tempCard(String label, int temp, SensorHistory history,
      ThermalAnalysis thermal) {
    final color = _tempColor(temp);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: _labelStyle),
              const SizedBox(width: 8),
              _trendBadge(thermal.trend),
              const Spacer(),
              Text('$temp\u00B0C',
                  style: _bigValueStyle.copyWith(color: color)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: Text(
                'Min: ${history.min.toStringAsFixed(0)}\u00B0  '
                'Max: ${history.max.toStringAsFixed(0)}\u00B0  '
                'Avg: ${history.average.toStringAsFixed(1)}\u00B0  '
                'StdDev: ${history.stdDev.toStringAsFixed(1)}',
                style: _tinyStyle,
              )),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Rate: ${thermal.ratePerSec >= 0 ? '+' : ''}${thermal.ratePerSec.toStringAsFixed(2)}C/s  '
            'Delta: ${thermal.deltaFromStart >= 0 ? '+' : ''}${thermal.deltaFromStart.toStringAsFixed(1)}C from start'
            '${thermal.secondsToCritical != null ? '  Critical in: ${thermal.secondsToCritical!.toStringAsFixed(0)}s' : ''}',
            style: _tinyStyle.copyWith(
              color: thermal.throttleLikely ? Colors.red : null,
            ),
          ),
          if (thermal.throttleLikely) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('THERMAL THROTTLING DETECTED',
                  style: _tinyStyle.copyWith(color: Colors.red, fontWeight: FontWeight.w600)),
            ),
          ],
          const SizedBox(height: 8),
          _progressBar(temp / 100.0, color),
        ],
      ),
    );
  }

  Widget _trendBadge(ThermalTrend trend) {
    String label;
    Color color;
    switch (trend) {
      case ThermalTrend.rising:
        label = 'RISING';
        color = Colors.orange;
      case ThermalTrend.falling:
        label = 'FALLING';
        color = Colors.greenAccent;
      case ThermalTrend.stable:
        label = 'STABLE';
        color = Colors.white54;
      case ThermalTrend.spiking:
        label = 'SPIKING';
        color = Colors.red;
      case ThermalTrend.unknown:
        label = '---';
        color = Colors.white24;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label, style: TextStyle(
          color: color, fontSize: 8, fontWeight: FontWeight.w600)),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  FAN CARDS (enhanced with efficiency)
  // ═══════════════════════════════════════════════════════════════

  Widget _fanCard(String label, int rpm, int duty, int maxDuty,
      SensorHistory rpmHistory, SensorHistory dutyHistory,
      FanEfficiency efficiency) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _labelStyle),
          const SizedBox(height: 8),
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$rpm',
                      style: _bigValueStyle.copyWith(
                          color: const Color(0xFF44DDFF))),
                  Text('RPM', style: _tinyStyle),
                ],
              ),
              const SizedBox(width: 24),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$duty%', style: _medValueStyle),
                  Text('DUTY', style: _tinyStyle),
                ],
              ),
              const SizedBox(width: 24),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${efficiency.rpmPerDutyPercent.toStringAsFixed(0)}',
                      style: _medValueStyle.copyWith(color: Colors.purple[200])),
                  Text('RPM/1%', style: _tinyStyle),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'RPM  Min:${rpmHistory.min.toStringAsFixed(0)} '
            'Max:${rpmHistory.max.toStringAsFixed(0)} '
            'Avg:${rpmHistory.average.toStringAsFixed(0)}',
            style: _tinyStyle,
          ),
          Text(
            'Duty Min:${dutyHistory.min.toStringAsFixed(0)}% '
            'Max:${dutyHistory.max.toStringAsFixed(0)}% '
            'Avg:${dutyHistory.average.toStringAsFixed(1)}%  '
            'Response: ~${efficiency.estimatedResponseMs}ms',
            style: _tinyStyle,
          ),
          const SizedBox(height: 6),
          _progressBar(duty / 100.0, const Color(0xFF44DDFF)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  QUICK BATTERY PANEL (overview tab)
  // ═══════════════════════════════════════════════════════════════

  Widget _batteryQuickPanel() {
    final bat = _bat;
    final percent = bat.estimatedChargePercent;
    final color = _batteryColor(percent, bat.charging);

    return _card(
      child: Row(
        children: [
          Icon(bat.charging ? Icons.battery_charging_full : Icons.battery_std,
              color: color, size: 28),
          const SizedBox(width: 8),
          Text('$percent%', style: _bigValueStyle.copyWith(color: color, fontSize: 24)),
          const SizedBox(width: 16),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(bat.powerSourceStr, style: _labelStyle.copyWith(color: color)),
              Text(
                '${bat.voltageV.toStringAsFixed(2)}V | '
                'Health: ${bat.healthPercent.toStringAsFixed(1)}% | '
                'Wear: ${bat.wearPercent.toStringAsFixed(1)}% | '
                '${bat.powerW != 0 ? '${bat.powerW.toStringAsFixed(1)}W' : 'Idle'}'
                '${bat.estimatedHoursRemaining != null ? ' | ~${bat.estimatedHoursRemaining!.toStringAsFixed(1)}h left' : ''}'
                '${bat.estimatedHoursToFull != null ? ' | ~${bat.estimatedHoursToFull!.toStringAsFixed(1)}h to full' : ''}',
                style: _tinyStyle,
              ),
            ],
          )),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  SESSION STATS SUMMARY (overview tab)
  // ═══════════════════════════════════════════════════════════════

  Widget _sessionStatsSummary() {
    final s = _monitor.sessionStats;
    return _card(
      child: Wrap(
        spacing: 24,
        runSpacing: 8,
        children: [
          _statChip('CPU Peak', '${s.cpuTempPeak}C', _tempColor(s.cpuTempPeak)),
          _statChip('GPU Peak', '${s.gpuTempPeak}C', _tempColor(s.gpuTempPeak)),
          _statChip('F1 Peak', '${s.fan1RPMPeak} RPM', const Color(0xFF44DDFF)),
          _statChip('F2 Peak', '${s.fan2RPMPeak} RPM', const Color(0xFF44DDFF)),
          _statChip('Avg Latency', '${s.pollLatencyAvg.toStringAsFixed(1)}ms', Colors.amber),
          _statChip('Peak Latency', '${s.pollLatencyPeak}ms', Colors.amber),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: TextStyle(
            color: color, fontSize: 13, fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()])),
        Text(label, style: _tinyStyle),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  GCC-STYLE INDIVIDUAL FAN CONTROL HELPERS
  // ═══════════════════════════════════════════════════════════════

  void _applyActiveCurves() {
    final cpuCurve = FanCurve(
      name: 'Custom CPU',
      points: List.from(_customCpuPoints),
    );
    final gpuCurve = FanCurve(
      name: 'Custom GPU',
      points: List.from(_customGpuPoints),
    );
    _fanCtrl.setCurveMode(cpuCurve: cpuCurve, gpuCurve: gpuCurve);
    setState(() {});
  }

  Widget _presetModeButton(String label, bool active, VoidCallback onTap) {
    const activeColor = Color(0xFF44DDFF);
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? activeColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? activeColor.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: _labelStyle.copyWith(
              fontSize: 11,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              color: active ? Colors.white : Colors.white54,
            ),
          ),
        ),
      ),
    );
  }

  Widget _overrideChip(String label, int speed) {
    final active = _fanCtrl.mode == FanMode.fixed && _fanCtrl.fixedDuty == speed;
    const activeColor = Color(0xFF44DDFF);
    return GestureDetector(
      onTap: () async {
        await _fanCtrl.setFixedDuty(speed);
        setState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? activeColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? activeColor.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          style: _tinyStyle.copyWith(
            color: active ? Colors.white : Colors.white60,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _gccControlRow({
    required String label,
    required int value,
    required String unit,
    required Color color,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 90,
          child: Text(label, style: _labelStyle.copyWith(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        // Step Down Button
        GestureDetector(
          onTap: () => onChanged(value - 1),
          onLongPress: () => onChanged(value - 5),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(Icons.remove, size: 14, color: Colors.white70),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.toDouble().clamp(0, 100),
            min: 0,
            max: 100,
            divisions: 100,
            activeColor: color,
            inactiveColor: Colors.white12,
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        // Step Up Button
        GestureDetector(
          onTap: () => onChanged(value + 1),
          onLongPress: () => onChanged(value + 5),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(Icons.add, size: 14, color: Colors.white70),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 45,
          child: Text(
            '$value$unit',
            textAlign: TextAlign.right,
            style: _monoStyle.copyWith(color: color, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  THERMAL ANALYSIS CARD (insights tab)
  // ═══════════════════════════════════════════════════════════════

  Widget _thermalAnalysisCard(String label, ThermalAnalysis thermal, int temp) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: _labelStyle),
              const SizedBox(width: 8),
              _trendBadge(thermal.trend),
              const Spacer(),
              Text('$temp\u00B0C', style: _medValueStyle.copyWith(
                  color: _tempColor(temp))),
            ],
          ),
          const Divider(height: 16, color: Colors.white12),
          _insightRow('Trend', _trendStr(thermal.trend)),
          _insightRow('Rate of Change',
              '${thermal.ratePerSec >= 0 ? '+' : ''}${thermal.ratePerSec.toStringAsFixed(3)} C/sec'),
          _insightRow('Delta from Session Start',
              '${thermal.deltaFromStart >= 0 ? '+' : ''}${thermal.deltaFromStart.toStringAsFixed(1)}C'),
          if (thermal.secondsToCritical != null)
            _insightRow('Time to Critical (95C)',
                '${thermal.secondsToCritical!.toStringAsFixed(0)} seconds',
                valueColor: Colors.red),
          _insightRow('Thermal Events (>${_monitor.thermalThreshold}C)',
              '${thermal.thermalEvents}',
              valueColor: thermal.thermalEvents > 0 ? Colors.orange : null),
          _insightRow('Time Above ${_monitor.thermalThreshold}C',
              '${thermal.timeAboveThreshold.toStringAsFixed(1)}s',
              valueColor: thermal.timeAboveThreshold > 10 ? Colors.orange : null),
          _insightRow('Throttle Detected',
              thermal.throttleLikely ? 'YES' : 'No',
              valueColor: thermal.throttleLikely ? Colors.red : Colors.greenAccent),
        ],
      ),
    );
  }

  String _trendStr(ThermalTrend trend) {
    switch (trend) {
      case ThermalTrend.rising: return 'Rising (getting hotter)';
      case ThermalTrend.falling: return 'Falling (cooling down)';
      case ThermalTrend.stable: return 'Stable (steady state)';
      case ThermalTrend.spiking: return 'Spiking! (rapid increase)';
      case ThermalTrend.unknown: return 'Insufficient data';
    }
  }

  Widget _insightRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: _tinyStyle)),
          Text(value, style: _monoStyle.copyWith(
              color: valueColor, fontSize: 10)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  FAN EFFICIENCY CARD (insights tab)
  // ═══════════════════════════════════════════════════════════════

  Widget _fanEfficiencyCard(String label, FanEfficiency eff,
      int rpm, int duty) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _labelStyle),
          const Divider(height: 16, color: Colors.white12),
          _insightRow('Current RPM', '$rpm'),
          _insightRow('Current Duty', '$duty%'),
          _insightRow('RPM per 1% Duty',
              eff.rpmPerDutyPercent.toStringAsFixed(1)),
          _insightRow('Avg RPM per 1% Duty (session)',
              eff.avgRpmPerDuty.toStringAsFixed(1)),
          _insightRow('Estimated Response Time',
              '~${eff.estimatedResponseMs}ms'),
          _insightRow('Efficiency Rating',
              _efficiencyRating(eff.rpmPerDutyPercent),
              valueColor: _efficiencyColor(eff.rpmPerDutyPercent)),
        ],
      ),
    );
  }

  String _efficiencyRating(double rpmPerDuty) {
    if (rpmPerDuty > 100) return 'Excellent';
    if (rpmPerDuty > 60) return 'Good';
    if (rpmPerDuty > 30) return 'Average';
    if (rpmPerDuty > 0) return 'Low';
    return 'N/A';
  }

  Color _efficiencyColor(double rpmPerDuty) {
    if (rpmPerDuty > 100) return Colors.greenAccent;
    if (rpmPerDuty > 60) return Colors.green;
    if (rpmPerDuty > 30) return Colors.amber;
    if (rpmPerDuty > 0) return Colors.orange;
    return Colors.white38;
  }

  // ═══════════════════════════════════════════════════════════════
  //  SESSION STATISTICS DETAILED (insights tab)
  // ═══════════════════════════════════════════════════════════════

  Widget _sessionStatsDetailed() {
    final s = _monitor.sessionStats;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Session: ${_formatDuration(s.sessionDuration)}',
              style: _labelStyle.copyWith(fontSize: 11)),
          const Divider(height: 12, color: Colors.white12),

          // Temperature section
          Text('TEMPERATURES', style: _tinyStyle.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: _sessionStatRow('CPU Peak', '${s.cpuTempPeak}C')),
              Expanded(child: _sessionStatRow('CPU Min', '${s.cpuTempMin == 999 ? '--' : s.cpuTempMin}C')),
              Expanded(child: _sessionStatRow('GPU Peak', '${s.gpuTempPeak}C')),
              Expanded(child: _sessionStatRow('GPU Min', '${s.gpuTempMin == 999 ? '--' : s.gpuTempMin}C')),
            ],
          ),
          const SizedBox(height: 8),

          // Fan section
          Text('FANS', style: _tinyStyle.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: _sessionStatRow('F1 RPM Peak', '${s.fan1RPMPeak}')),
              Expanded(child: _sessionStatRow('F2 RPM Peak', '${s.fan2RPMPeak}')),
              Expanded(child: _sessionStatRow('F1 Duty Peak', '${s.fan1DutyPeak}%')),
              Expanded(child: _sessionStatRow('F2 Duty Peak', '${s.fan2DutyPeak}%')),
            ],
          ),
          const SizedBox(height: 8),

          // Polling
          Text('POLLING', style: _tinyStyle.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: _sessionStatRow('Avg Latency', '${s.pollLatencyAvg.toStringAsFixed(1)} ms')),
              Expanded(child: _sessionStatRow('Peak Latency', '${s.pollLatencyPeak} ms')),
              Expanded(child: _sessionStatRow('WMI Reads', '${_wmi.totalReads}')),
              Expanded(child: _sessionStatRow('WMI Writes', '${_wmi.totalWrites}')),
            ],
          ),

          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () {
              _monitor.resetHistory();
              setState(() {});
            },
            icon: const Icon(Icons.restart_alt, size: 14),
            label: const Text('Reset Session Stats'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              foregroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: _monoStyle.copyWith(fontSize: 10)),
          Text(label, style: _tinyStyle.copyWith(fontSize: 8)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  THERMAL EVENT LOG (insights tab)
  // ═══════════════════════════════════════════════════════════════

  Widget _thermalEventLog() {
    final events = _monitor.thermalEvents;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${events.length} events logged this session',
              style: _tinyStyle.copyWith(fontStyle: FontStyle.italic)),
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No thermal events detected yet. Events are logged when '
                  'temperatures cross the threshold (${_monitor.thermalThreshold}C), '
                  'spike (>5C jump), or throttle is detected.',
                  style: _mutedStyle),
            )
          else ...[
            const SizedBox(height: 8),
            ...events.reversed.take(20).map((e) {
              Color eventColor;
              switch (e.type) {
                case 'threshold': eventColor = Colors.orange;
                case 'spike': eventColor = Colors.amber;
                case 'throttle': eventColor = Colors.red;
                default: eventColor = Colors.white54;
              }
              final time = '${e.timestamp.hour.toString().padLeft(2, '0')}:'
                  '${e.timestamp.minute.toString().padLeft(2, '0')}:'
                  '${e.timestamp.second.toString().padLeft(2, '0')}';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text(time, style: _monoStyle.copyWith(fontSize: 9)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: eventColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(e.type.toUpperCase(),
                          style: TextStyle(color: eventColor, fontSize: 8,
                              fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 8),
                    Text(e.sensor, style: _tinyStyle.copyWith(
                        fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(e.description,
                        style: _monoStyle.copyWith(fontSize: 9))),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  FULL BATTERY PANEL (battery tab)
  // ═══════════════════════════════════════════════════════════════

  Widget _batteryFullPanel() {
    final bat = _bat;
    final percent = bat.estimatedChargePercent;
    final color = _batteryColor(percent, bat.charging);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row
          Row(
            children: [
              Icon(
                bat.charging ? Icons.battery_charging_full
                    : percent > 80 ? Icons.battery_full
                    : percent > 50 ? Icons.battery_5_bar
                    : percent > 20 ? Icons.battery_3_bar
                    : Icons.battery_1_bar,
                color: color, size: 32,
              ),
              const SizedBox(width: 8),
              Text('$percent%', style: _bigValueStyle.copyWith(color: color)),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(bat.powerSourceStr,
                      style: _labelStyle.copyWith(color: color)),
                  Text(bat.statusStr, style: _tinyStyle),
                ],
              ),
              const Spacer(),
              if (bat.critical)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
                  ),
                  child: Text('CRITICAL',
                      style: _tinyStyle.copyWith(color: Colors.red)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _progressBar(percent / 100.0, color),
          const SizedBox(height: 12),

          // Capacity
          Row(
            children: [
              _batteryStatItem('Remaining', '${bat.remainingCapacityWh.toStringAsFixed(1)} Wh'),
              _batteryStatItem('Full Charge', '${bat.fullChargedCapacityWh.toStringAsFixed(1)} Wh'),
              _batteryStatItem('Design', '${bat.designedCapacityWh.toStringAsFixed(1)} Wh'),
              _batteryStatItem('Health', '${bat.healthPercent.toStringAsFixed(1)}%'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _batteryStatItem('Voltage', '${bat.voltageV.toStringAsFixed(3)} V'),
              _batteryStatItem('Charge Rate',
                  bat.chargeRateMW > 0 ? '${bat.chargeRateW.toStringAsFixed(1)} W' : '--'),
              _batteryStatItem('Discharge Rate',
                  bat.dischargeRateMW > 0 ? '${bat.dischargeRateW.toStringAsFixed(1)} W' : '--'),
              _batteryStatItem('Power',
                  bat.powerW != 0 ? '${bat.powerW.toStringAsFixed(1)} W' : 'Idle'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _batteryStatItem('Chemistry', bat.chemistryStr),
              _batteryStatItem('Cycles', '${bat.cycleCount}'),
              _batteryStatItem('Tech', bat.technology == 1 ? 'Rechargeable' : 'Non-rechargeable'),
              _batteryStatItem('Name', bat.deviceName),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _batteryStatItem('Manufacturer', bat.manufactureName),
              _batteryStatItem('Serial', bat.serialNumber),
              _batteryStatItem('UniqueID', bat.uniqueID),
              if (bat.estimatedHoursRemaining != null)
                _batteryStatItem('Est. Remaining',
                    '${bat.estimatedHoursRemaining!.toStringAsFixed(1)} h')
              else if (bat.estimatedHoursToFull != null)
                _batteryStatItem('Est. Full',
                    '${bat.estimatedHoursToFull!.toStringAsFixed(1)} h')
              else
                _batteryStatItem('Est. Time', '--'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _batteryStatItem(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _tinyStyle),
          Text(value, style: _labelStyle.copyWith(fontSize: 11)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  BATTERY HEALTH & WEAR PANEL
  // ═══════════════════════════════════════════════════════════════

  Widget _batteryHealthPanel() {
    final bat = _bat;
    final healthColor = bat.healthPercent > 80
        ? Colors.greenAccent : bat.healthPercent > 60
        ? Colors.amber : Colors.red;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Health gauge
              SizedBox(
                width: 80,
                height: 80,
                child: CustomPaint(
                  painter: _GaugePainter(
                    value: bat.healthPercent / 100.0,
                    color: healthColor,
                    label: '${bat.healthPercent.toStringAsFixed(1)}%',
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Battery Health', style: _labelStyle),
                  const SizedBox(height: 4),
                  _insightRow('Health Rating',
                      _healthRating(bat.healthPercent),
                      valueColor: healthColor),
                  _insightRow('Wear Level',
                      '${bat.wearPercent.toStringAsFixed(1)}%',
                      valueColor: bat.wearPercent > 20 ? Colors.orange : Colors.greenAccent),
                  _insightRow('Capacity Lost',
                      '${bat.capacityLostWh.toStringAsFixed(1)} Wh'),
                  _insightRow('Design Capacity',
                      '${bat.designedCapacityWh.toStringAsFixed(1)} Wh'),
                  _insightRow('Full Charge Capacity',
                      '${bat.fullChargedCapacityWh.toStringAsFixed(1)} Wh'),
                  _insightRow('Cycle Count', '${bat.cycleCount}'),
                  if (bat.cycleCount > 0 && bat.wearPercent > 0)
                    _insightRow('Wear per Cycle',
                        '${(bat.wearPercent / bat.cycleCount).toStringAsFixed(3)}%'),
                ],
              )),
            ],
          ),
        ],
      ),
    );
  }

  String _healthRating(double health) {
    if (health > 95) return 'Excellent';
    if (health > 85) return 'Good';
    if (health > 70) return 'Fair';
    if (health > 50) return 'Poor';
    return 'Critical - Consider Replacement';
  }

  // ═══════════════════════════════════════════════════════════════
  //  POWER MANAGEMENT PANEL
  // ═══════════════════════════════════════════════════════════════

  Widget _powerManagementPanel() {
    final bat = _bat;
    final s = _monitor.sessionStats;
    final totalTime = s.timeOnACSeconds + s.timeOnBatterySeconds;
    final acPercent = totalTime > 0 ? (s.timeOnACSeconds / totalTime * 100) : 0.0;
    final batPercent = totalTime > 0 ? (s.timeOnBatterySeconds / totalTime * 100) : 0.0;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Power source indicator
          Row(
            children: [
              Icon(bat.powerOnline ? Icons.power : Icons.battery_std,
                  color: bat.powerOnline ? Colors.greenAccent : Colors.amber,
                  size: 24),
              const SizedBox(width: 8),
              Text(bat.powerOnline ? 'AC Power Connected' : 'Running on Battery',
                  style: _labelStyle.copyWith(
                      color: bat.powerOnline ? Colors.greenAccent : Colors.amber)),
            ],
          ),
          const Divider(height: 16, color: Colors.white12),

          // Current power draw
          _insightRow('Current Power Draw',
              bat.powerW != 0
                  ? '${bat.powerW.abs().toStringAsFixed(1)} W ${bat.powerW > 0 ? '(charging)' : '(discharging)'}'
                  : 'Idle'),
          _insightRow('Current Voltage', '${bat.voltageV.toStringAsFixed(3)} V'),
          if (bat.charging)
            _insightRow('Charge Rate', '${bat.chargeRateW.toStringAsFixed(1)} W'),
          if (bat.discharging)
            _insightRow('Discharge Rate', '${bat.dischargeRateW.toStringAsFixed(1)} W'),

          const Divider(height: 16, color: Colors.white12),

          // Time estimates
          if (bat.estimatedHoursRemaining != null) ...[
            _insightRow('Est. Battery Life',
                _formatDuration(Duration(
                    minutes: (bat.estimatedHoursRemaining! * 60).round())),
                valueColor: Colors.amber),
            _insightRow('At Current Workload',
                '${bat.dischargeRateW.toStringAsFixed(1)} W draw'),
          ],
          if (bat.estimatedHoursToFull != null)
            _insightRow('Est. Time to Full',
                _formatDuration(Duration(
                    minutes: (bat.estimatedHoursToFull! * 60).round())),
                valueColor: Colors.greenAccent),

          const Divider(height: 16, color: Colors.white12),

          // AC vs Battery time
          Text('POWER SOURCE DISTRIBUTION', style: _tinyStyle.copyWith(
              fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          if (totalTime > 0) ...[
            // Visual bar
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 8,
                child: Row(
                  children: [
                    if (acPercent > 0)
                      Expanded(
                        flex: acPercent.round().clamp(1, 100),
                        child: Container(color: Colors.greenAccent.withValues(alpha: 0.7)),
                      ),
                    if (batPercent > 0)
                      Expanded(
                        flex: batPercent.round().clamp(1, 100),
                        child: Container(color: Colors.amber.withValues(alpha: 0.7)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(child: Text(
                    'AC: ${_formatDuration(Duration(seconds: s.timeOnACSeconds.round()))} (${acPercent.toStringAsFixed(1)}%)',
                    style: _tinyStyle.copyWith(color: Colors.greenAccent))),
                Expanded(child: Text(
                    'Battery: ${_formatDuration(Duration(seconds: s.timeOnBatterySeconds.round()))} (${batPercent.toStringAsFixed(1)}%)',
                    style: _tinyStyle.copyWith(color: Colors.amber))),
              ],
            ),
          ] else
            Text('No data yet', style: _mutedStyle),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  ENERGY TRACKING PANEL
  // ═══════════════════════════════════════════════════════════════

  Widget _energyTrackingPanel() {
    final s = _monitor.sessionStats;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _energyStat('Total Energy Consumed',
                  '${s.totalEnergyConsumedWh.toStringAsFixed(3)} Wh',
                  Icons.trending_down, Colors.orange)),
              Expanded(child: _energyStat('Total Energy Charged',
                  '${s.totalEnergyChargedWh.toStringAsFixed(3)} Wh',
                  Icons.trending_up, Colors.greenAccent)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _energyStat('Avg Power Draw',
                  '${s.avgPowerDrawW.toStringAsFixed(1)} W',
                  Icons.speed, Colors.amber)),
              Expanded(child: _energyStat('Peak Discharge',
                  '${s.peakDischargePowerW.toStringAsFixed(1)} W',
                  Icons.flash_on, Colors.red)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _energyStat('Peak Charge Rate',
                  '${s.peakChargePowerW.toStringAsFixed(1)} W',
                  Icons.bolt, Colors.greenAccent)),
              Expanded(child: _energyStat('Power Samples',
                  '${s.powerSampleCount}',
                  Icons.analytics, Colors.white54)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _energyStat(String label, String value, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color.withValues(alpha: 0.6)),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: _monoStyle.copyWith(color: color, fontSize: 11)),
            Text(label, style: _tinyStyle),
          ],
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  BATTERY HISTORY SECTION
  // ═══════════════════════════════════════════════════════════════

  Widget _batteryHistorySection() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sparkline('Battery %', _monitor.history.batteryPercent, '%',
              _batteryColor(_bat.estimatedChargePercent, _bat.charging)),
          const SizedBox(height: 12),
          _sparkline('Voltage', _monitor.history.batteryVoltage, ' V',
              Colors.purple),
          const SizedBox(height: 12),
          _sparkline('Power', _monitor.history.batteryPower, ' W',
              Colors.amber),
          const SizedBox(height: 12),
          _sparkline('Charge Rate', _monitor.history.batteryChargeRate, ' W',
              Colors.greenAccent),
          const SizedBox(height: 12),
          _sparkline('Discharge Rate', _monitor.history.batteryDischargeRate, ' W',
              Colors.orange),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  HISTORY GRAPHS (overview tab)
  // ═══════════════════════════════════════════════════════════════

  Widget _historySection() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sparkline('CPU Temp', _monitor.history.cpuTemp, '\u00B0C',
              _tempColor(_snap.cpuTemp)),
          const SizedBox(height: 12),
          _sparkline('GPU Temp', _monitor.history.gpuTemp, '\u00B0C',
              _tempColor(_snap.gpuTemp)),
          const SizedBox(height: 12),
          _sparkline('Fan1 RPM', _monitor.history.fan1RPM, ' RPM',
              const Color(0xFF44DDFF)),
          const SizedBox(height: 12),
          _sparkline('Fan2 RPM', _monitor.history.fan2RPM, ' RPM',
              const Color(0xFF44DDFF)),
          const SizedBox(height: 12),
          _sparkline('Fan1 Duty', _monitor.history.fan1Duty, '%',
              Colors.purple[200]!),
          const SizedBox(height: 12),
          _sparkline('Fan2 Duty', _monitor.history.fan2Duty, '%',
              Colors.purple[200]!),
          const SizedBox(height: 12),
          _sparkline('Poll Latency', _monitor.history.pollLatency, 'ms',
              Colors.amber),
        ],
      ),
    );
  }

  Widget _sparkline(
      String label, SensorHistory history, String unit, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: _labelStyle.copyWith(fontSize: 10)),
            const Spacer(),
            Text(
              '${history.latest.toStringAsFixed(history.latest == history.latest.roundToDouble() ? 0 : 1)}$unit',
              style: _labelStyle.copyWith(color: color, fontSize: 10),
            ),
            const SizedBox(width: 8),
            Text(
              'min:${history.min.toStringAsFixed(0)} max:${history.max.toStringAsFixed(0)} avg:${history.average.toStringAsFixed(1)}',
              style: _tinyStyle.copyWith(fontSize: 8),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 30,
          width: double.infinity,
          child: CustomPaint(
            painter: _SparklinePainter(
              values: history.toList(),
              color: color,
              minVal: history.isEmpty ? 0 : history.min,
              maxVal: history.isEmpty ? 100 : history.max,
            ),
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  KEYBOARD RGB HELPERS (combined from LiquidRGB)
  // ═══════════════════════════════════════════════════════════════

  void _stopRgbEffect() {
    _rgbTimer?.cancel();
    _rgbTimer = null;
    _rgbRunning = false;
    _rgbEffect = 'None';
  }

  void _startRgbEffect(String type, {int intervalMs = 40}) {
    _stopRgbEffect();
    _rgbEffect = type;
    _rgbStartTime = DateTime.now();
    _rgbRunning = true;
    _rgbTickCount = 0;

    _rgbTimer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) {
      if (!_rgbRunning || !_wmiAvailable) {
        timer.cancel();
        return;
      }
      _rgbTickCount++;
      final elapsed = DateTime.now().difference(_rgbStartTime).inMilliseconds / 1000.0;
      final spd = _rgbSpeed;

      Color finalColor = Color.fromARGB(255, _rgbR.round(), _rgbG.round(), _rgbB.round());

      switch (type) {
        case 'Static':
          finalColor = Color.fromARGB(255, _rgbR.round(), _rgbG.round(), _rgbB.round());
          _applyKeyboardColor(finalColor);
          timer.cancel(); // No need to continue ticking for Static
          return;

        case 'Breathing':
          final v = (math.sin(elapsed * spd * math.pi) + 1) / 2;
          finalColor = Color.fromARGB(
            255,
            (_rgbR * v).round(),
            (_rgbG * v).round(),
            (_rgbB * v).round(),
          );
          break;

        case 'Rainbow':
          final h = (elapsed * 36 * spd) % 360;
          finalColor = HSVColor.fromAHSV(1.0, h, 1.0, 1.0).toColor();
          break;

        case 'ColorCycle':
          final t = (math.sin(elapsed * spd * math.pi) + 1) / 2;
          final startC = Color.fromARGB(255, _rgbR.round(), _rgbG.round(), _rgbB.round());
          final endC = Color.fromARGB(255, 255 - _rgbR.round(), 255 - _rgbG.round(), 255 - _rgbB.round());
          finalColor = Color.lerp(startC, endC, t) ?? startC;
          break;

        case 'Strobe':
          final on = (math.sin(elapsed * spd * math.pi * 4)) > 0;
          finalColor = on
              ? Color.fromARGB(255, _rgbR.round(), _rgbG.round(), _rgbB.round())
              : const Color(0xFF000000);
          break;

        case 'Candle':
          final rand = math.Random();
          final f = rand.nextDouble() * 0.4 + 0.6;
          final rs = rand.nextDouble() * 30;
          finalColor = Color.fromARGB(
            255,
            (255 * f).round(),
            ((100 + rs) * f).round(),
            (20 * f).round(),
          );
          break;

        case 'Police':
          final phase = (elapsed * 4 * spd).floor() % 4;
          switch (phase) {
            case 0:
              finalColor = const Color(0xFFFF0000);
              break;
            case 1:
              finalColor = const Color(0xFF000000);
              break;
            case 2:
              finalColor = const Color(0xFF0000FF);
              break;
            case 3:
              finalColor = const Color(0xFF000000);
              break;
          }
          break;

        case 'NeonPulse':
          const cols = [
            Color(0xFFFF00FF), Color(0xFF00FFFF), Color(0xFFFFFF00),
            Color(0xFFFF0064), Color(0xFF00FF64), Color(0xFF6400FF),
          ];
          final pos = (elapsed * spd * 0.5) % cols.length;
          final i = pos.floor();
          final t = pos - i;
          final j = (i + 1) % cols.length;
          final c = Color.lerp(cols[i], cols[j], t) ?? cols[i];
          final pulse = (math.sin(elapsed * spd * math.pi * 3) + 1) / 2 * 0.3 + 0.7;
          finalColor = Color.fromARGB(
            255,
            (c.red * pulse).round().clamp(0, 255),
            (c.green * pulse).round().clamp(0, 255),
            (c.blue * pulse).round().clamp(0, 255),
          );
          break;

        case 'Sunset':
          const cols = [
            Color(0xFFFF3C00), Color(0xFFFF7800), Color(0xFFFFB428),
            Color(0xFFC8321E), Color(0xFFB41E3C), Color(0xFFFF5014),
          ];
          final pos = (elapsed * spd * 0.3) % cols.length;
          final i = pos.floor();
          final t = pos - i;
          final j = (i + 1) % cols.length;
          finalColor = Color.lerp(cols[i], cols[j], t) ?? cols[i];
          break;

        case 'Ocean':
          const cols = [
            Color(0xFF0032B4), Color(0xFF0096C8), Color(0xFF00C8C8),
            Color(0xFF0064A0), Color(0xFF143C8C),
          ];
          final pos = (elapsed * spd * 0.3) % cols.length;
          final i = pos.floor();
          final t = pos - i;
          final j = (i + 1) % cols.length;
          final c = Color.lerp(cols[i], cols[j], t) ?? cols[i];
          final w = (math.sin(elapsed * spd * math.pi * 0.8) + 1) / 2 * 0.2 + 0.8;
          finalColor = Color.fromARGB(
            255,
            (c.red * w).round().clamp(0, 255),
            (c.green * w).round().clamp(0, 255),
            (c.blue * w).round().clamp(0, 255),
          );
          break;
      }

      _applyKeyboardColor(finalColor);
    });
  }

  void _applyKeyboardColor(Color c) {
    if (mounted) {
      setState(() {
        _rgbPreviewColor = c;
      });
    }
    final r = c.red.clamp(0, 255);
    final g = c.green.clamp(0, 255);
    final b = c.blue.clamp(0, 255);
    final arg = 4026531840 + (b * 65536) + (r * 256) + g;
    _wmi.write('SetKBLED', arg);
  }

  void _applyKeyboardBrightness(int level) {
    final arg = 4093640704 + level.clamp(0, 255);
    _wmi.write('SetKBLED', arg);
  }

  Widget _rgbSliderRow(String label, double value, Color color, ValueChanged<double> onChanged, {double min = 0, double max = 255, int? divisions, String Function(double)? valueSuffix}) {
    return Row(
      children: [
        SizedBox(
          width: 50,
          child: Text(label, style: _labelStyle.copyWith(fontSize: 11)),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions ?? (max - min).round(),
            activeColor: color,
            inactiveColor: Colors.white12,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 45,
          child: Text(
            valueSuffix != null ? valueSuffix(value) : value.round().toString(),
            style: _monoStyle.copyWith(color: color, fontSize: 11),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  Widget _presetChip(Color color, String name) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _rgbR = color.red.toDouble();
          _rgbG = color.green.toDouble();
          _rgbB = color.blue.toDouble();
          _rgbPreviewColor = color;
        });
        if (color == const Color(0xFF000000)) {
          _stopRgbEffect();
          _applyKeyboardColor(const Color(0xFF000000));
        } else {
          _startRgbEffect('Static');
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
        ),
        child: Text(
          name,
          style: _tinyStyle.copyWith(
            color: color == const Color(0xFF000000) ? Colors.white70 : color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _effectButton(String effectName, IconData icon) {
    final active = _rgbRunning && _rgbEffect == effectName;
    return GestureDetector(
      onTap: () {
        _startRgbEffect(effectName);
      },
      child: Container(
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF44DDFF).withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? const Color(0xFF44DDFF).withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 14,
              color: active ? const Color(0xFF44DDFF) : Colors.white54,
            ),
            const SizedBox(width: 6),
            Text(
              effectName == 'ColorCycle' ? 'Color Cycle' : effectName == 'NeonPulse' ? 'Neon Pulse' : effectName,
              style: _labelStyle.copyWith(
                color: active ? Colors.white : Colors.white70,
                fontSize: 11,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  SHARED WIDGETS
  // ═══════════════════════════════════════════════════════════════

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: child,
    );
  }

  Widget _statusBadge() {
    final isAuto = _snap.autoMode;
    final color = isAuto ? Colors.greenAccent : Colors.amber;
    final label = isAuto ? 'AUTO' : _fanCtrl.mode.name.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }

  Widget _progressBar(double fraction, Color color) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: LinearProgressIndicator(
          value: fraction.clamp(0, 1),
          backgroundColor: Colors.white.withValues(alpha: 0.06),
          valueColor: AlwaysStoppedAnimation(color.withValues(alpha: 0.7)),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════

  static Color _tempColor(int temp) {
    if (temp < 50) return Colors.greenAccent;
    if (temp < 70) return Colors.amber;
    if (temp < 85) return Colors.orange;
    return Colors.red;
  }

  static Color _batteryColor(int percent, bool charging) {
    if (charging) return Colors.greenAccent;
    if (percent > 60) return Colors.greenAccent;
    if (percent > 30) return Colors.amber;
    if (percent > 15) return Colors.orange;
    return Colors.red;
  }

  static String _fmtHex(int val) =>
      '0x${val.toRadixString(16).toUpperCase().padLeft(8, '0')} ($val)';

  static String _fmtHexRaw(int val) {
    if (val == 0xFFFFFFFF || val == 4294967295 || val == -1) {
      return '0xFFFFFFFF (auto)';
    }
    return '0x${val.toRadixString(16).toUpperCase().padLeft(8, '0')} ($val)';
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  // ═══════════════════════════════════════════════════════════════
  //  TEXT STYLES
  // ═══════════════════════════════════════════════════════════════

  TextStyle get _titleStyle => GoogleFonts.saira(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: 4,
      );

  TextStyle get _sectionStyle => GoogleFonts.saira(
        color: Colors.white54,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 2,
      );

  TextStyle get _headerStyle => GoogleFonts.saira(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      );

  TextStyle get _labelStyle => GoogleFonts.saira(
        color: Colors.white70,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      );

  TextStyle get _bigValueStyle => GoogleFonts.saira(
        color: Colors.white,
        fontSize: 28,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  TextStyle get _medValueStyle => GoogleFonts.saira(
        color: Colors.white70,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  TextStyle get _tinyStyle => GoogleFonts.saira(
        color: Colors.white38,
        fontSize: 9,
        fontWeight: FontWeight.w400,
      );

  TextStyle get _monoStyle => GoogleFonts.sourceCodePro(
        color: Colors.white54,
        fontSize: 10,
        fontWeight: FontWeight.w400,
      );

  TextStyle get _mutedStyle => GoogleFonts.saira(
        color: Colors.white38,
        fontSize: 12,
      );
}

// ═══════════════════════════════════════════════════════════════
//  SPARKLINE PAINTER
// ═══════════════════════════════════════════════════════════════

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final double minVal;
  final double maxVal;

  _SparklinePainter({
    required this.values,
    required this.color,
    required this.minVal,
    required this.maxVal,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final range = (maxVal - minVal).clamp(1.0, double.infinity);
    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = size.height - ((values[i] - minVal) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);

    // Fill under the line
    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => true;
}

// ═══════════════════════════════════════════════════════════════
//  CURVE PAINTER (for custom curve editor)
// ═══════════════════════════════════════════════════════════════

class _CurvePainter extends CustomPainter {
  final List<FanCurvePoint> cpuPoints;
  final List<FanCurvePoint> gpuPoints;
  final int selectedFanTab; // 0 = CPU, 1 = GPU
  final int selectedNodeIndex;
  final int cpuTemp;
  final int gpuTemp;

  _CurvePainter({
    required this.cpuPoints,
    required this.gpuPoints,
    required this.selectedFanTab,
    required this.selectedNodeIndex,
    required this.cpuTemp,
    required this.gpuTemp,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (cpuPoints.isEmpty || gpuPoints.isEmpty) return;

    // Colors
    const cpuColor = Color(0xFF66FF88);  // Vibrant green
    const gpuColor = Color(0xFFFF9933);  // Vibrant orange

    // Background grid
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 0.5;

    // Horizontal grid lines (duty: 0, 10, 20, ..., 100)
    for (int d = 0; d <= 100; d += 10) {
      final y = size.height - (d / 100.0) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Vertical grid lines (temp: 35, 40, 50, 60, 70, 80, 90, 100)
    final gridTemps = [35, 40, 50, 60, 70, 80, 90, 100];
    for (int t in gridTemps) {
      final x = ((t - 30) / (100 - 30)) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    // Draw GPU Curve (Orange Line) first so CPU draws on top if overlapping
    final gpuPath = Path();
    for (int i = 0; i < gpuPoints.length; i++) {
      final x = ((gpuPoints[i].temp - 30) / (100 - 30)) * size.width;
      final y = size.height - (gpuPoints[i].duty / 100.0) * size.height;
      if (i == 0) {
        gpuPath.moveTo(x, y);
      } else {
        gpuPath.lineTo(x, y);
      }
    }
    canvas.drawPath(
      gpuPath,
      Paint()
        ..color = gpuColor.withValues(alpha: selectedFanTab == 1 ? 0.9 : 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = selectedFanTab == 1 ? 2.5 : 1.5
        ..strokeJoin = StrokeJoin.round,
    );

    // Draw CPU Curve (Green Line)
    final cpuPath = Path();
    for (int i = 0; i < cpuPoints.length; i++) {
      final x = ((cpuPoints[i].temp - 30) / (100 - 30)) * size.width;
      final y = size.height - (cpuPoints[i].duty / 100.0) * size.height;
      if (i == 0) {
        cpuPath.moveTo(x, y);
      } else {
        cpuPath.lineTo(x, y);
      }
    }
    canvas.drawPath(
      cpuPath,
      Paint()
        ..color = cpuColor.withValues(alpha: selectedFanTab == 0 ? 0.9 : 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = selectedFanTab == 0 ? 2.5 : 1.5
        ..strokeJoin = StrokeJoin.round,
    );

    // Draw points for GPU
    for (int i = 0; i < gpuPoints.length; i++) {
      final pt = gpuPoints[i];
      final x = ((pt.temp - 30) / (100 - 30)) * size.width;
      final y = size.height - (pt.duty / 100.0) * size.height;
      final isSelected = selectedFanTab == 1 && selectedNodeIndex == i;

      canvas.drawCircle(
        Offset(x, y),
        isSelected ? 6 : 3,
        Paint()..color = gpuColor.withValues(alpha: selectedFanTab == 1 ? 1.0 : 0.4),
      );
      if (isSelected) {
        canvas.drawCircle(
          Offset(x, y),
          9,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    // Draw points for CPU
    for (int i = 0; i < cpuPoints.length; i++) {
      final pt = cpuPoints[i];
      final x = ((pt.temp - 30) / (100 - 30)) * size.width;
      final y = size.height - (pt.duty / 100.0) * size.height;
      final isSelected = selectedFanTab == 0 && selectedNodeIndex == i;

      canvas.drawCircle(
        Offset(x, y),
        isSelected ? 6 : 3,
        Paint()..color = cpuColor.withValues(alpha: selectedFanTab == 0 ? 1.0 : 0.4),
      );
      if (isSelected) {
        canvas.drawCircle(
          Offset(x, y),
          9,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    // Draw real-time temperature vertical bars
    if (cpuTemp >= 30 && cpuTemp <= 100) {
      final curX = ((cpuTemp - 30) / (100 - 30)) * size.width;
      canvas.drawLine(
        Offset(curX, 0),
        Offset(curX, size.height),
        Paint()
          ..color = cpuColor.withValues(alpha: 0.3)
          ..strokeWidth = 1,
      );
    }
    if (gpuTemp >= 30 && gpuTemp <= 100) {
      final curX = ((gpuTemp - 30) / (100 - 30)) * size.width;
      canvas.drawLine(
        Offset(curX, 0),
        Offset(curX, size.height),
        Paint()
          ..color = gpuColor.withValues(alpha: 0.3)
          ..strokeWidth = 1,
      );
    }

    // Labels & Texts
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // X-Axis Temp labels
    for (int t in gridTemps) {
      final x = ((t - 30) / (100 - 30)) * size.width;
      textPainter.text = TextSpan(
        text: '${t}C',
        style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 7, fontFamily: 'monospace'),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x - textPainter.width / 2, size.height - 10));
    }

    // Y-Axis Speed labels (0%, 50%, 100%)
    final labelDuties = [0, 50, 100];
    for (int d in labelDuties) {
      final y = size.height - (d / 100.0) * size.height;
      textPainter.text = TextSpan(
        text: '$d%',
        style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 7, fontFamily: 'monospace'),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(2, y - (d == 100 ? 0 : d == 0 ? 8 : 4)));
    }
  }

  @override
  bool shouldRepaint(_CurvePainter old) => true;
}

// ═══════════════════════════════════════════════════════════════
//  GAUGE PAINTER (for battery health)
// ═══════════════════════════════════════════════════════════════

class _GaugePainter extends CustomPainter {
  final double value; // 0.0 to 1.0
  final Color color;
  final String label;

  _GaugePainter({
    required this.value,
    required this.color,
    required this.label,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;

    // Background arc
    final bgPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      2.4, // start angle (roughly 140 degrees)
      4.3, // sweep angle (roughly 260 degrees)
      false,
      bgPaint,
    );

    // Value arc
    final valuePaint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      2.4,
      4.3 * value.clamp(0, 1),
      false,
      valuePaint,
    );

    // Label
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(
      center.dx - textPainter.width / 2,
      center.dy - textPainter.height / 2 + 2,
    ));
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.value != value || old.color != color;
}
