import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Low-level WMI communication service using a persistent PowerShell process.
///
/// Single process handles ALL reads and writes to CLEVO_GET WMI class,
/// plus battery data queries.
///
/// CRITICAL FIX: Uses `Invoke-WmiMethod` for reads (not `$instance.InvokeMethod`
/// which silently fails on this hardware returning garbage data).
/// Uses `$instance.PSBase.InvokeMethod` for writes (with input params).
class WmiService {
  bool _initialized = false;
  bool _available = false;
  bool _ready = false;
  String _lastError = '';
  int _reconnectCount = 0;
  static const _maxReconnects = 3;

  Process? _process;
  String? _checkScriptPath;
  String? _cmdScriptPath;

  // Response handling
  Completer<Map<String, dynamic>>? _pendingResponse;
  static const _responseTimeout = Duration(seconds: 8);

  // Stats
  int _totalReads = 0;
  int _totalWrites = 0;
  int _totalErrors = 0;
  DateTime? _lastSuccessfulRead;

  bool get isAvailable => _available;
  bool get isReady => _ready;
  String get lastError => _lastError;
  int get reconnectCount => _reconnectCount;
  int get totalReads => _totalReads;
  int get totalWrites => _totalWrites;
  int get totalErrors => _totalErrors;
  DateTime? get lastSuccessfulRead => _lastSuccessfulRead;

  /// Check script: verifies CLEVO_GET class (or any Clevo equivalent) exists and lists its methods.
  static const _checkScript = r'''
try {
    $className = "CLEVO_GET"
    $w = Get-WmiObject -Namespace root\WMI -Class $className -ErrorAction SilentlyContinue
    if (-not $w) {
        # Search dynamically for any other WMI class containing Clevo/CLEVO
        $allClevo = Get-WmiObject -Namespace root\WMI -List | Where-Object { $_.Name -like "*CLEVO*" -or $_.Name -like "*Clevo*" }
        if ($allClevo) {
            $className = $allClevo[0].Name
        } else {
            throw "No Clevo WMI class found in root\WMI."
        }
    }
    $methods = ([wmiclass]"root\WMI:$className").Methods
    $names = ($methods | ForEach-Object { $_.Name }) -join ','
    Write-Output "HWREADY:$names"
} catch {
    Write-Output "HWFAIL:$($_.Exception.Message)"
}
''';

  /// Persistent command server.
  ///
  /// Protocol:
  ///   READ:seq:MethodName          -> {"seq":N,"ok":true,"method":"...","data":uint32}
  ///   WRITE:seq:MethodName:uint32  -> {"seq":N,"ok":true,"method":"...","wrote":true}
  ///   BATCH:seq:Method1,Method2,.. -> {"seq":N,"ok":true,"results":{...}}
  ///   BATTERY:seq                  -> {"seq":N,"ok":true,"battery":{...}}
  ///   PING:seq                     -> {"seq":N,"ok":true,"pong":true}
  ///
  /// CRITICAL: READ and BATCH use Invoke-WmiMethod (the cmdlet), NOT
  /// $instance.InvokeMethod() which fails on no-input-param methods.
  /// WRITE uses $instance.PSBase.InvokeMethod() with input parameters.
  static const _cmdScript = r'''
$ErrorActionPreference = 'Continue'
$instance = $null
$className = "CLEVO_GET"
try {
    $instance = Get-WmiObject -Namespace root\WMI -Class $className -ErrorAction SilentlyContinue
    if (-not $instance) {
        $allClevo = Get-WmiObject -Namespace root\WMI -List | Where-Object { $_.Name -like "*CLEVO*" -or $_.Name -like "*Clevo*" }
        if ($allClevo) {
            $className = $allClevo[0].Name
            $instance = Get-WmiObject -Namespace root\WMI -Class $className -ErrorAction Stop
        } else {
            throw "No Clevo WMI class found in root\WMI."
        }
    }
} catch {
    $err = @{seq=0; ok=$false; error=$_.Exception.Message} | ConvertTo-Json -Compress
    [Console]::Out.WriteLine($err)
    [Console]::Out.Flush()
    exit 1
}
$wmiClass = [wmiclass]"root\WMI:$className"

foreach ($line in $input) {
    $cmd = $line.Trim()
    if ($cmd -eq '') { continue }

    try {
        $parts = $cmd.Split(':', 4)
        $verb = $parts[0]
        $seq = 0
        if ($parts.Length -ge 2) { $seq = [int]$parts[1] }

        if ($verb -eq 'PING') {
            $resp = @{seq=$seq; ok=$true; pong=$true} | ConvertTo-Json -Compress
            [Console]::Out.WriteLine($resp)
            [Console]::Out.Flush()
        }
        elseif ($verb -eq 'READ') {
            $methodName = $parts[2]
            $r = Invoke-WmiMethod -InputObject $instance -Name $methodName
            $val = [long][uint32]$r.Data
            $resp = @{seq=$seq; ok=$true; method=$methodName; data=$val} | ConvertTo-Json -Compress
            [Console]::Out.WriteLine($resp)
            [Console]::Out.Flush()
        }
        elseif ($verb -eq 'WRITE') {
            $methodName = $parts[2]
            [uint32]$data = [uint32]$parts[3]
            try {
                $inP = $wmiClass.GetMethodParameters($methodName)
                if ($inP -and $inP.Properties['Data']) {
                    $inP['Data'] = $data
                    $instance.PSBase.InvokeMethod($methodName, $inP, $null) | Out-Null
                } else {
                    $instance.$methodName($data) | Out-Null
                }
            } catch {
                try {
                    $instance.$methodName($data) | Out-Null
                } catch {}
            }
            $resp = @{seq=$seq; ok=$true; method=$methodName; wrote=$true} | ConvertTo-Json -Compress
            [Console]::Out.WriteLine($resp)
            [Console]::Out.Flush()
        }
        elseif ($verb -eq 'BATCH') {
            $methods = $parts[2].Split(',')
            $results = @{}
            foreach ($m in $methods) {
                $m = $m.Trim()
                if ($m -eq '') { continue }
                try {
                    $r = Invoke-WmiMethod -InputObject $instance -Name $m
                    $results[$m] = [long][uint32]$r.Data
                } catch {
                    $results[$m] = -1
                }
            }
            $resp = @{seq=$seq; ok=$true; results=$results} | ConvertTo-Json -Compress
            [Console]::Out.WriteLine($resp)
            [Console]::Out.Flush()
        }
        elseif ($verb -eq 'BATTERY') {
            $bat = @{}
            try {
                $w32 = Get-WmiObject Win32_Battery -ErrorAction SilentlyContinue
                if ($w32) {
                    $bat['estimatedChargePercent'] = [int]$w32.EstimatedChargeRemaining
                    $bat['batteryStatus'] = [int]$w32.BatteryStatus
                    $bat['availability'] = [int]$w32.Availability
                    if ($w32.DesignVoltage) { $bat['designVoltage'] = [int]$w32.DesignVoltage }
                    $bat['name'] = [string]$w32.Name
                    $bat['chemistry'] = [int]$w32.Chemistry
                    $bat['status'] = [string]$w32.Status
                }
            } catch {}
            try {
                $bs = Get-WmiObject -Namespace root\WMI -Class BatteryStatus -ErrorAction SilentlyContinue
                if ($bs) {
                    $bat['charging'] = [bool]$bs.Charging
                    $bat['discharging'] = [bool]$bs.Discharging
                    $bat['powerOnline'] = [bool]$bs.PowerOnline
                    $bat['critical'] = [bool]$bs.Critical
                    $bat['remainingCapacityMWh'] = [int]$bs.RemainingCapacity
                    $bat['voltageMV'] = [int]$bs.Voltage
                    $bat['chargeRateMW'] = [int]$bs.ChargeRate
                    $bat['dischargeRateMW'] = [int]$bs.DischargeRate
                }
            } catch {}
            try {
                $bfc = Get-WmiObject -Namespace root\WMI -Class BatteryFullChargedCapacity -ErrorAction SilentlyContinue
                if ($bfc) {
                    $bat['fullChargedCapacityMWh'] = [int]$bfc.FullChargedCapacity
                }
            } catch {}
            try {
                $bsd = Get-WmiObject -Namespace root\WMI -Class BatteryStaticData -ErrorAction SilentlyContinue
                if ($bsd) {
                    $bat['designedCapacityMWh'] = [int]$bsd.DesignedCapacity
                    $bat['deviceName'] = [string]$bsd.DeviceName
                    $bat['manufactureName'] = [string]$bsd.ManufactureName
                    $bat['serialNumber'] = [string]$bsd.SerialNumber
                    $bat['uniqueID'] = [string]$bsd.UniqueID
                    $bat['technology'] = [int]$bsd.Technology
                }
            } catch {}
            try {
                $bcc = Get-WmiObject -Namespace root\WMI -Class BatteryCycleCount -ErrorAction SilentlyContinue
                if ($bcc) {
                    $bat['cycleCount'] = [int]$bcc.CycleCount
                }
            } catch {}
            $resp = @{seq=$seq; ok=$true; battery=$bat} | ConvertTo-Json -Compress
            [Console]::Out.WriteLine($resp)
            [Console]::Out.Flush()
        }
        else {
            $resp = @{seq=$seq; ok=$false; error="Unknown verb: $verb"} | ConvertTo-Json -Compress
            [Console]::Out.WriteLine($resp)
            [Console]::Out.Flush()
        }
    } catch {
        $resp = @{seq=0; ok=$false; error=$_.Exception.Message} | ConvertTo-Json -Compress
        [Console]::Out.WriteLine($resp)
        [Console]::Out.Flush()
    }
}
''';

  /// List of available WMI methods (populated by check script).
  List<String> _availableMethods = [];
  List<String> get availableMethods => List.unmodifiable(_availableMethods);

  int _seqCounter = 0;

  /// Initialize: check WMI, start command process.
  Future<bool> initialize() async {
    if (_initialized) return _available;
    _initialized = true;
    return _startProcess();
  }

  /// Internal: start (or restart) the PowerShell process.
  Future<bool> _startProcess() async {
    try {
      final tempDir = Directory.systemTemp;

      // Write scripts to temp
      final checkFile = File('${tempDir.path}\\lc_wmi_check.ps1');
      await checkFile.writeAsString(_checkScript);
      _checkScriptPath = checkFile.path;

      final cmdFile = File('${tempDir.path}\\lc_wmi_cmd.ps1');
      await cmdFile.writeAsString(_cmdScript);
      _cmdScriptPath = cmdFile.path;

      // Run check script
      final checkResult = await Process.run('powershell', [
        '-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass',
        '-File', _checkScriptPath!,
      ]).timeout(const Duration(seconds: 15), onTimeout: () {
        return ProcessResult(0, 1, 'HWTIMEOUT', '');
      });

      final checkOutput = checkResult.stdout.toString().trim();

      if (!checkOutput.startsWith('HWREADY')) {
        _available = false;
        _lastError = checkOutput.isEmpty
            ? 'WMI check failed (exit ${checkResult.exitCode})'
            : checkOutput;
        return false;
      }

      // Parse available methods from HWREADY:method1,method2,...
      if (checkOutput.contains(':')) {
        final methodsStr = checkOutput.substring(checkOutput.indexOf(':') + 1);
        _availableMethods =
            methodsStr.split(',').where((s) => s.isNotEmpty).toList();
      }

      // Start persistent command process
      _process = await Process.start('powershell', [
        '-NoProfile',
        '-NoLogo',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        _cmdScriptPath!,
      ]);

      // Listen to stdout for JSON responses
      _process!.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen(_handleResponse);

      // Drain stderr
      _process!.stderr.listen((_) {});

      // Monitor process exit — auto-reconnect
      _process!.exitCode.then((code) {
        _ready = false;
        if (_available && _reconnectCount < _maxReconnects) {
          _reconnectCount++;
          _lastError =
              'Process died (code $code), reconnecting (#$_reconnectCount)...';
          Future<void>.delayed(const Duration(seconds: 1), () {
            _initialized = false;
            _startProcess();
          });
        } else {
          _available = false;
          _lastError =
              'Process exited ($code) after $_reconnectCount reconnects';
        }
      });

      // Wait for PS to initialize WMI
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // Verify with a ping
      final ping = await _sendRaw('PING:${++_seqCounter}');
      if (ping == null || ping['ok'] != true) {
        _available = false;
        _lastError = 'Ping failed after process start';
        return false;
      }

      _available = true;
      _ready = true;
      return true;
    } catch (e) {
      _available = false;
      _lastError = e.toString();
      _process?.kill();
      _process = null;
      return false;
    }
  }

  /// Handle a JSON response line from PowerShell stdout.
  void _handleResponse(String line) {
    if (line.trim().isEmpty) return;
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      if (_pendingResponse != null && !_pendingResponse!.isCompleted) {
        _pendingResponse!.complete(json);
      }
    } catch (_) {
      // Ignore non-JSON output (PS startup noise, etc.)
    }
  }

  /// Send a raw command string and wait for JSON response.
  Future<Map<String, dynamic>?> _sendRaw(String cmd) async {
    if (_process == null) return null;

    // Skip if previous request still pending
    if (_pendingResponse != null && !_pendingResponse!.isCompleted) {
      return null;
    }

    _pendingResponse = Completer<Map<String, dynamic>>();

    try {
      _process!.stdin.writeln(cmd);
      await _process!.stdin.flush();

      final result = await _pendingResponse!.future
          .timeout(_responseTimeout, onTimeout: () {
        _totalErrors++;
        return <String, dynamic>{'ok': false, 'error': 'Timeout'};
      });
      return result;
    } catch (e) {
      _pendingResponse = null;
      _totalErrors++;
      return null;
    }
  }

  /// Read a single WMI method. Returns the uint32 data value, or null on error.
  Future<int?> read(String method) async {
    if (!_ready) return null;
    final seq = ++_seqCounter;
    final resp = await _sendRaw('READ:$seq:$method');
    if (resp == null || resp['ok'] != true) {
      _totalErrors++;
      return null;
    }
    _totalReads++;
    _lastSuccessfulRead = DateTime.now();
    return (resp['data'] as num?)?.toInt();
  }

  /// Write a WMI method with uint32 data. Returns true on success.
  Future<bool> write(String method, int data) async {
    if (!_ready) return false;
    final seq = ++_seqCounter;
    final resp = await _sendRaw('WRITE:$seq:$method:$data');
    if (resp == null || resp['ok'] != true) {
      _totalErrors++;
      return false;
    }
    _totalWrites++;
    return true;
  }

  /// Batch read multiple WMI methods in a single round-trip.
  Future<Map<String, int>?> batchRead(List<String> methods) async {
    if (!_ready || methods.isEmpty) return null;
    final seq = ++_seqCounter;
    final methodStr = methods.join(',');
    final resp = await _sendRaw('BATCH:$seq:$methodStr');
    if (resp == null || resp['ok'] != true) {
      _totalErrors++;
      return null;
    }
    _totalReads += methods.length;
    _lastSuccessfulRead = DateTime.now();

    final results = resp['results'] as Map<String, dynamic>?;
    if (results == null) return null;

    return results.map((k, v) => MapEntry(k, (v as num).toInt()));
  }

  /// Read battery data from multiple WMI classes in one round-trip.
  Future<Map<String, dynamic>?> readBattery() async {
    if (!_ready) return null;
    final seq = ++_seqCounter;
    final resp = await _sendRaw('BATTERY:$seq');
    if (resp == null || resp['ok'] != true) {
      _totalErrors++;
      return null;
    }
    _totalReads++;
    _lastSuccessfulRead = DateTime.now();
    return resp['battery'] as Map<String, dynamic>?;
  }

  /// Ping: verify the process is alive and responsive.
  Future<bool> ping() async {
    final seq = ++_seqCounter;
    final resp = await _sendRaw('PING:$seq');
    return resp != null && resp['ok'] == true;
  }

  /// Clean up: kill process, delete temp scripts.
  void dispose() {
    _ready = false;
    _available = false;

    try {
      _process?.kill();
    } catch (_) {}
    _process = null;

    for (final path in [_checkScriptPath, _cmdScriptPath]) {
      if (path != null) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
    }
  }
}
