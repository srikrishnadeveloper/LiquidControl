/// Data models for the OPTIMIZER and STORAGE tabs.

// ─────────────────────────────────────────────
//  Process info (top-N by memory)
// ─────────────────────────────────────────────

class ProcessInfo {
  final String name;
  final int pid;
  final double memMB;
  final double memPercent;

  const ProcessInfo({
    required this.name,
    required this.pid,
    required this.memMB,
    required this.memPercent,
  });

  factory ProcessInfo.fromJson(Map<String, dynamic> j) => ProcessInfo(
        name: (j['name'] as String?) ?? '?',
        pid: (j['pid'] as num?)?.toInt() ?? 0,
        memMB: (j['memMB'] as num?)?.toDouble() ?? 0,
        memPercent: (j['memPercent'] as num?)?.toDouble() ?? 0,
      );
}

// ─────────────────────────────────────────────
//  Memory snapshot
// ─────────────────────────────────────────────

class MemorySnapshot {
  final double totalMB;
  final double usedMB;
  final double freeMB;
  final double standbyMB;
  final double modifiedMB;
  final double commitMB;
  final double usedPercent;
  final List<ProcessInfo> topProcesses;

  const MemorySnapshot({
    required this.totalMB,
    required this.usedMB,
    required this.freeMB,
    required this.standbyMB,
    required this.modifiedMB,
    required this.commitMB,
    required this.usedPercent,
    required this.topProcesses,
  });

  factory MemorySnapshot.empty() => const MemorySnapshot(
        totalMB: 0,
        usedMB: 0,
        freeMB: 0,
        standbyMB: 0,
        modifiedMB: 0,
        commitMB: 0,
        usedPercent: 0,
        topProcesses: [],
      );

  factory MemorySnapshot.fromJson(Map<String, dynamic> j) {
    final procs = (j['processes'] as List<dynamic>? ?? [])
        .map((e) => ProcessInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    return MemorySnapshot(
      totalMB: (j['totalMB'] as num?)?.toDouble() ?? 0,
      usedMB: (j['usedMB'] as num?)?.toDouble() ?? 0,
      freeMB: (j['freeMB'] as num?)?.toDouble() ?? 0,
      standbyMB: (j['standbyMB'] as num?)?.toDouble() ?? 0,
      modifiedMB: (j['modifiedMB'] as num?)?.toDouble() ?? 0,
      commitMB: (j['commitMB'] as num?)?.toDouble() ?? 0,
      usedPercent: (j['usedPercent'] as num?)?.toDouble() ?? 0,
      topProcesses: procs,
    );
  }
}

// ─────────────────────────────────────────────
//  Drive info
// ─────────────────────────────────────────────

class DriveInfo {
  final String letter;
  final String label;
  final double totalGB;
  final double freeGB;
  final double usedGB;
  final double usedPercent;

  const DriveInfo({
    required this.letter,
    required this.label,
    required this.totalGB,
    required this.freeGB,
    required this.usedGB,
    required this.usedPercent,
  });

  factory DriveInfo.fromJson(Map<String, dynamic> j) => DriveInfo(
        letter: (j['letter'] as String?) ?? '?',
        label: (j['label'] as String?) ?? '',
        totalGB: (j['totalGB'] as num?)?.toDouble() ?? 0,
        freeGB: (j['freeGB'] as num?)?.toDouble() ?? 0,
        usedGB: (j['usedGB'] as num?)?.toDouble() ?? 0,
        usedPercent: (j['usedPercent'] as num?)?.toDouble() ?? 0,
      );
}

// ─────────────────────────────────────────────
//  Temp files breakdown
// ─────────────────────────────────────────────

class TempFilesInfo {
  final double userTempMB;
  final double winTempMB;
  final double prefetchMB;
  final double recycleBinMB;

  const TempFilesInfo({
    required this.userTempMB,
    required this.winTempMB,
    required this.prefetchMB,
    required this.recycleBinMB,
  });

  double get totalMB => userTempMB + winTempMB + prefetchMB + recycleBinMB;

  factory TempFilesInfo.empty() => const TempFilesInfo(
        userTempMB: 0,
        winTempMB: 0,
        prefetchMB: 0,
        recycleBinMB: 0,
      );

  factory TempFilesInfo.fromJson(Map<String, dynamic> j) => TempFilesInfo(
        userTempMB: (j['userTempMB'] as num?)?.toDouble() ?? 0,
        winTempMB: (j['winTempMB'] as num?)?.toDouble() ?? 0,
        prefetchMB: (j['prefetchMB'] as num?)?.toDouble() ?? 0,
        recycleBinMB: (j['recycleBinMB'] as num?)?.toDouble() ?? 0,
      );
}

// ─────────────────────────────────────────────
//  Startup program entry
// ─────────────────────────────────────────────

class StartupEntry {
  final String name;
  final String publisher;
  final String command;
  final bool enabled;

  const StartupEntry({
    required this.name,
    required this.publisher,
    required this.command,
    required this.enabled,
  });

  factory StartupEntry.fromJson(Map<String, dynamic> j) => StartupEntry(
        name: (j['name'] as String?) ?? '?',
        publisher: (j['publisher'] as String?) ?? '',
        command: (j['command'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
      );
}

// ─────────────────────────────────────────────
//  Full system info snapshot
// ─────────────────────────────────────────────

class SystemInfoSnapshot {
  final MemorySnapshot memory;
  final List<DriveInfo> drives;
  final TempFilesInfo tempFiles;
  final DateTime? lastBootTime;
  final Duration uptimeSinceBoot;
  final List<StartupEntry> startupPrograms;
  final DateTime fetchedAt;

  SystemInfoSnapshot({
    required this.memory,
    required this.drives,
    required this.tempFiles,
    this.lastBootTime,
    required this.uptimeSinceBoot,
    required this.startupPrograms,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  factory SystemInfoSnapshot.empty() => SystemInfoSnapshot(
        memory: MemorySnapshot.empty(),
        drives: [],
        tempFiles: TempFilesInfo.empty(),
        uptimeSinceBoot: Duration.zero,
        startupPrograms: [],
      );

  factory SystemInfoSnapshot.fromJson(Map<String, dynamic> j) {
    final drives = (j['drives'] as List<dynamic>? ?? [])
        .map((e) => DriveInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    final startup = (j['startup'] as List<dynamic>? ?? [])
        .map((e) => StartupEntry.fromJson(e as Map<String, dynamic>))
        .toList();

    DateTime? bootTime;
    final bootStr = j['lastBootTime'] as String?;
    if (bootStr != null && bootStr.isNotEmpty) {
      try {
        bootTime = DateTime.parse(bootStr);
      } catch (_) {}
    }

    final uptimeSeconds = (j['uptimeSeconds'] as num?)?.toInt() ?? 0;

    return SystemInfoSnapshot(
      memory: MemorySnapshot.fromJson(
          j['memory'] as Map<String, dynamic>? ?? {}),
      drives: drives,
      tempFiles: TempFilesInfo.fromJson(
          j['tempFiles'] as Map<String, dynamic>? ?? {}),
      lastBootTime: bootTime,
      uptimeSinceBoot: Duration(seconds: uptimeSeconds),
      startupPrograms: startup,
    );
  }
}

// ─────────────────────────────────────────────
//  Optimize result
// ─────────────────────────────────────────────

class OptimizeResult {
  final double beforeMB;
  final double afterMB;
  final List<String> areasProcessed;
  final DateTime timestamp;
  final String? error;

  OptimizeResult({
    required this.beforeMB,
    required this.afterMB,
    required this.areasProcessed,
    DateTime? timestamp,
    this.error,
  }) : timestamp = timestamp ?? DateTime.now();

  double get freedMB => (beforeMB - afterMB).clamp(0, double.infinity);

  factory OptimizeResult.fromJson(Map<String, dynamic> j) => OptimizeResult(
        beforeMB: (j['beforeMB'] as num?)?.toDouble() ?? 0,
        afterMB: (j['afterMB'] as num?)?.toDouble() ?? 0,
        areasProcessed: (j['areas'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        error: j['error'] as String?,
      );

  factory OptimizeResult.error(String msg) => OptimizeResult(
        beforeMB: 0,
        afterMB: 0,
        areasProcessed: [],
        error: msg,
      );
}

// ─────────────────────────────────────────────
//  Clean temp result
// ─────────────────────────────────────────────

class CleanTempResult {
  final int deletedCount;
  final double freedMB;
  final String? error;

  const CleanTempResult({
    required this.deletedCount,
    required this.freedMB,
    this.error,
  });

  factory CleanTempResult.fromJson(Map<String, dynamic> j) => CleanTempResult(
        deletedCount: (j['deletedCount'] as num?)?.toInt() ?? 0,
        freedMB: (j['freedMB'] as num?)?.toDouble() ?? 0,
        error: j['error'] as String?,
      );

  factory CleanTempResult.error(String msg) => CleanTempResult(
        deletedCount: 0,
        freedMB: 0,
        error: msg,
      );
}
