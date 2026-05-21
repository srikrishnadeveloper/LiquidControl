# Gigabyte/Clevo WMI Control Protocol Specification

A detailed reference guide to the low-level WMI (Windows Management Instrumentation) interface used to control fan speeds, keyboard backlight lighting, and system states on **Gigabyte G5 MF** and other Clevo ODM-based laptops.

This document describes how the hardware protocol works, how commands are encoded, and contains clean reference codes for developers who want to build their own custom controllers or scripts.

---

## 1. WMI Namespace and Class

* **Namespace:** `root\WMI`
* **Class:** `CLEVO_GET`
* **Requirement:** Administrator privileges are required to interact with this class.

If you are using PowerShell, you can query available methods on the class like this:

```powershell
# Run as Administrator
([wmiclass]"root\WMI:CLEVO_GET").Methods | Select-Object Name
```

On compatible laptops, this will return:
- `Fan1Info`
- `Fan2Info`
- `GetFan12RPM`
- `SetFanDuty`
- `SetFanAutoDuty`
- `SetKBLED` (if single-zone RGB backlight is supported)

---

## 2. Keyboard RGB Backlight Control (`SetKBLED`)

The `SetKBLED` method accepts a single 32-bit unsigned integer (`uint32`) containing a command base and packed values representing color or brightness.

### A. Set Color (Zone 0)
* **Command Base (Sub-command):** `0xF0000000` (decimal `4026531840`)
* **Byte Layout (Big-Endian):** `0xF0_BB_RR_GG`
  * `BB` = Blue (0-255)
  * `RR` = Red (0-255)
  * `GG` = Green (0-255)
* **Byte Order:** Blue-Red-Green (NOT standard RGB)

**Formula:**
$$\text{Argument} = 4026531840 + (\text{Blue} \times 65536) + (\text{Red} \times 256) + \text{Green}$$

**Example (Pure Magenta: R=255, G=0, B=255):**
$$\text{Argument} = 4026531840 + (255 \times 65536) + (255 \times 256) + 0 = 4043313920 \quad (\text{Hex: } \texttt{0xF101FF00})$$

```powershell
# PowerShell Code
$wmi = Get-WmiObject -Namespace root\WMI -Class CLEVO_GET
$colorArg = [uint32](4026531840 + (255 * 65536) + (255 * 256) + 0)
$wmi.SetKBLED($colorArg)
```

---

### B. Set Keyboard Brightness
* **Command Base (Sub-command):** `0xF4000000` (decimal `4093640704`)
* **Byte Layout (Big-Endian):** `0xF4_00_00_LL`
  * `LL` = Brightness Level (`10` to `255`)

**Formula:**
$$\text{Argument} = 4093640704 + \text{Level}$$

**Example (Maximum Brightness: Level = 255):**
$$\text{Argument} = 4093640704 + 255 = 4093640959 \quad (\text{Hex: } \texttt{0xF40000FF})$$

```powershell
# PowerShell Code
$wmi = Get-WmiObject -Namespace root\WMI -Class CLEVO_GET
$brightArg = [uint32](4093640704 + 255)
$wmi.SetKBLED($brightArg)
```

---

## 3. Fan Speed Monitoring and Control

### A. Reading Current Fan State (`Fan1Info` & `Fan2Info`)
These methods return a packed 32-bit integer containing temperature, current EC duty, and maximum supported duty.

* **Fan 1 (CPU):** Call `Fan1Info`
* **Fan 2 (GPU):** Call `Fan2Info`

**Unpacking Code (Big-Endian):**
* **Temperature:** `(val >> 16) & 0xFF`
* **Duty %:** `(val >> 8) & 0xFF`
* **Max Duty:** `val & 0xFF`

```dart
// Dart Code Example
final raw = results['Fan1Info'] ?? 0;
final cpuTemp = (raw >> 16) & 0xFF; // In Celsius
final cpuDuty = (raw >> 8) & 0xFF;  // In % (0-100)
final maxDuty = raw & 0xFF;         // Usually 100 or 255
```

---

### B. Reading Fan RPMs (`GetFan12RPM`)
Returns a packed 32-bit integer containing tachometer clock/period readings for both fans.

* **Unpacking Code (Big-Endian):**
  * **Fan 1 (CPU) Raw:** `(val >> 16) & 0xFFFF`
  * **Fan 2 (GPU) Raw:** `val & 0xFFFF`

**The RPM Multiplier:**
On Gigabyte G5 MF (and similar Clevo systems), the actual physical RPM of the fan is calculated by multiplying the raw registers by **`16`**.
$$\text{RPM} = \text{RawValue} \times 16$$
*(Note: Older systems or different ODM platforms used `8` or `30`, but `16` is correct for modern single-zone G5 laptops spinning up to ~6000 RPM).*

```dart
// Dart Code Example
final raw = results['GetFan12RPM'] ?? 0;
final fan1RPM = ((raw >> 16) & 0xFFFF) * 16;
final fan2RPM = (raw & 0xFFFF) * 16;
```

---

### C. Manual Fan Control (`SetFanAutoDuty` & `SetFanDuty`)

To control fan speeds manually, you **must** disengage the embedded controller's (EC) automatic control loop first. If you write to `SetFanDuty` without disabling auto-mode, the EC will immediately overwrite your values, making manual control appear broken.

#### Step 1: Switch to Manual Mode
Write `1` to the WMI method `SetFanAutoDuty` to disable EC auto-control:
```powershell
# PowerShell Code
$wmi = Get-WmiObject -Namespace root\WMI -Class CLEVO_GET
$wmi.SetFanAutoDuty(1) # 1 = Manual Mode, 0 = Auto (EC Controlled)
```

#### Step 2: Set Manual Fan Duty Percentage
Write a percentage value (`20` to `100`) to the WMI method `SetFanDuty`:
```powershell
# PowerShell Code
$wmi.SetFanDuty(75) # Set both fans to 75% duty cycle
```

#### Step 3: Revert to Auto Mode
Write `0` to `SetFanAutoDuty` to hand back control to the EC:
```powershell
# PowerShell Code
$wmi.SetFanAutoDuty(0) # Revert to Auto Mode
```

---

## 4. Minimum Working Example (PowerShell CLI)

Save this code block as `set-clevo-cooling.ps1` and run as Administrator to set manual fan speed:

```powershell
# Require Admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Error "Please run this script as Administrator!"
    exit 1
}

# Connect to Clevo WMI Class
$wmi = Get-WmiObject -Namespace root\WMI -Class CLEVO_GET

# 1. Switch to Manual Mode
Write-Host "Switching fans to Manual Mode..." -ForegroundColor Yellow
$wmi.SetFanAutoDuty(1) | Out-Null

# 2. Set fan duty to 80%
Write-Host "Setting fan duty to 80%..." -ForegroundColor Cyan
$wmi.SetFanDuty(80) | Out-Null

# Wait for 10 seconds to let fans spin up
Start-Sleep -Seconds 10

# Read current RPMs
$rpmRaw = $wmi.GetFan12RPM().Data
$cpuRPM = (($rpmRaw -shr 16) -band 0xFFFF) * 16
$gpuRPM = ($rpmRaw -band 0xFFFF) * 16
Write-Host "Current Speeds: CPU Peak: $cpuRPM RPM | GPU Peak: $gpuRPM RPM" -ForegroundColor Green

# 3. Reset to automatic EC control
Write-Host "Reverting back to Auto Mode..." -ForegroundColor Yellow
$wmi.SetFanAutoDuty(0) | Out-Null
Write-Host "Done!" -ForegroundColor Green
```

---

## 5. Summary Table of WMI Control Calls

| Functionality | WMI Method | Parameter Type | Value Range / Description |
|---|---|---|---|
| **Keyboard LED Color** | `SetKBLED` | `UInt32` | `4026531840 + (B*65536) + (R*256) + G` |
| **Keyboard LED Brightness** | `SetKBLED` | `UInt32` | `4093640704 + Level` (10 to 255) |
| **Set Fan Control Mode** | `SetFanAutoDuty` | `UInt32` | `0` = Auto (EC), `1` = Manual |
| **Set Manual Fan Duty** | `SetFanDuty` | `UInt32` | `20` to `100` (Duty Percentage) |
| **Get Fan Temperature & Duty** | `Fan1Info` / `Fan2Info` | Read-only | Pack byte layout: `Temp (b2)`, `Duty (b1)`, `MaxDuty (b0)` |
| **Get Fan RPM Counters** | `GetFan12RPM` | Read-only | Packed: `CPU Raw (upper 16)`, `GPU Raw (lower 16)`. Multiply by `16` for RPM |
