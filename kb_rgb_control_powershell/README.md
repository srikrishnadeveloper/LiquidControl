# KB RGB Control

**Keyboard RGB lighting control app for the Gigabyte G5 MF laptop (Clevo single-zone backlight)**

A lightweight PowerShell + WPF GUI that gives you full, real-time control over your keyboard's RGB backlight — with 10 built-in lighting effects, live sliders, and a debug panel — all without needing Gigabyte Control Center running.

---

## Screenshots

> **Run the app to see it live — dark themed WPF window, 620×640px**

The UI features:
- Color swatch that live-previews whatever the keyboard is showing
- R / G / B sliders (0–255 each)
- Speed (0.2× – 4.0×) and Brightness (10–255) sliders
- 10 effect buttons + a red STOP button
- Live debug/status console at the bottom

---

## Supported Hardware

| Field | Value |
|---|---|
| **Laptop** | Gigabyte G5 MF |
| **ODM** | Clevo |
| **Keyboard** | Single-zone RGB backlight |
| **WMI Interface** | `root\WMI : CLEVO_GET.SetKBLED(UInt32)` |
| **Driver** | `AcpiBridge.sys` (ships with the Clevo/Gigabyte platform) |

> **Other Clevo-based laptops** (Metabox, Sager, XMG, etc.) that expose the same `CLEVO_GET` WMI class should work too. Run `Get-WmiObject -Namespace root\WMI -Class CLEVO_GET` as Administrator to check.

---

## Requirements

- **Windows 10 / 11**
- **PowerShell 5.1** (built-in, no install needed)
- **Administrator rights** (required for WMI hardware access — the app auto-requests UAC elevation)
- **`AcpiBridge.sys` / Clevo WMI driver** installed (comes with Gigabyte Control Center or the Clevo driver package)
- **`ps2exe` module** — only needed if you want to recompile the `.exe` from source

---

## Installation

### Option A — Run the compiled EXE (easiest)

1. Download or clone this repository
2. Double-click **`KB RGB Control.exe`**
3. Accept the UAC admin prompt
4. Done — the window opens immediately

### Option B — Run the PowerShell script directly

```powershell
# From an elevated PowerShell prompt, or just double-click:
powershell -ExecutionPolicy Bypass -File "kb-rgb-control.ps1"
```

The script will self-elevate via UAC if not already running as Administrator.

### Option C — Create a desktop shortcut

Right-click the desktop → New → Shortcut → Target:

```
powershell -ExecutionPolicy Bypass -WindowStyle Normal -File "C:\Path\To\kb-rgb-control.ps1"
```

Check **"Run as administrator"** in the shortcut's Properties → Advanced.

---

## How to Use

| Step | Action |
|---|---|
| 1 | Double-click the desktop shortcut or `KB RGB Control.exe` |
| 2 | Accept the UAC admin prompt |
| 3 | Use the **R / G / B** sliders to mix a color |
| 4 | Click an **effect button** (Static, Breathing, Rainbow, …) |
| 5 | Adjust **Speed** to change how fast animated effects run |
| 6 | Adjust **Bright** to dim or brighten the backlight |
| 7 | Click **STOP** to turn off the backlight and halt all effects |

The **debug panel** at the bottom shows live status, tick count, and any errors.

---

## Lighting Effects

| # | Button | What it does |
|---|---|---|
| 1 | **Static** | Solid color from the RGB sliders |
| 2 | **Breathing** | Fades the selected color in and out (sine wave) |
| 3 | **Rainbow** | Full HSV hue wheel cycle |
| 4 | **Color Cycle** | Oscillates between the selected color and its complement |
| 5 | **Strobe** | Fast on/off flash of the selected color |
| 6 | **Candle** | Warm randomized orange/yellow flicker |
| 7 | **Police** | Alternating red / black / blue / black phases |
| 8 | **Neon Pulse** | Smooth crossfade through neon colors with brightness pulse |
| 9 | **Sunset** | Slow blend through warm sunset tones (orange → red → amber) |
| 10 | **Ocean** | Slow blend through cool ocean tones (blue → teal → cyan) with wave shimmer |

---

## Hardware Protocol

The app talks to the keyboard through the **Clevo WMI interface** — the exact same path that Gigabyte Control Center uses internally. No direct I/O port access, no registry changes, no firmware writes.

### WMI Details

```
Namespace : root\WMI
Class     : CLEVO_GET
Method    : SetKBLED(UInt32)
```

### Command Encoding

**Set color (sub-command `0xF0`):**

```
Argument = 0xF0_BB_RR_GG

Byte layout (big-endian view of the 32-bit value):
  F0 = sub-command (Zone 0 color)
  BB = Blue  (00-FF)
  RR = Red   (00-FF)
  GG = Green (00-FF)

Note: byte order is Blue-Red-Green, NOT the standard RGB order.

Formula:
  [uint32](4026531840 + (Blue * 65536) + (Red * 256) + Green)
```

**Set brightness (sub-command `0xF4`):**

```
Argument = 0xF4_00_00_LL

  F4 = sub-command (brightness)
  LL = Level (00-FF)

Formula:
  [uint32](4093640704 + Level)
```

**Example — pure red at full brightness:**

```powershell
# Brightness
$brightnessArg = [uint32](4093640704 + 255)    # = 0xF40000FF
# Color: R=255, G=0, B=0
$colorArg      = [uint32](4026531840 + (0 * 65536) + (255 * 256) + 0)  # = 0xF000FF00

$kb = Get-WmiObject -Namespace root\WMI -Class CLEVO_GET
$kb.SetKBLED($brightnessArg)
$kb.SetKBLED($colorArg)
```

---

## File Reference

```
KB RGB Control/
├── KB RGB Control.exe       Compiled app — double-click to run (no console)
├── kb-rgb-control.ps1       Main GUI source — edit this, then recompile
├── kb-rgb.ico               Custom icon (5 embedded sizes)
├── set-keyboard-color.ps1   CLI utility — set a single static color
├── set-keyboard-rainbow.ps1 CLI utility — standalone rainbow loop
└── README.md                This file
```

### CLI Utilities

**`set-keyboard-color.ps1`** — set a specific color from the command line:

```powershell
# Default: red
.\set-keyboard-color.ps1

# Custom color
.\set-keyboard-color.ps1 -Red 0 -Green 200 -Blue 255 -Brightness 200
```

**`set-keyboard-rainbow.ps1`** — run a rainbow cycle from the terminal:

```powershell
# Default: infinite loop, 10s/cycle, 50ms frame delay
.\set-keyboard-rainbow.ps1

# Custom: 5 cycles, 8 seconds each, pastel colors
.\set-keyboard-rainbow.ps1 -Cycles 5 -CycleDuration 8 -Saturation 0.6

# Parameters:
#   -CycleDuration  <seconds>    Time for one full hue sweep (default: 10)
#   -FrameDelay     <ms>         Milliseconds between frames (default: 50)
#   -Cycles         <n>          0 = infinite (default: 0)
#   -Brightness     <0-255>      Keyboard brightness (default: 255)
#   -Saturation     <0.0-1.0>    Color purity (default: 1.0)
```

---

## Architecture

### Self-Elevation

On launch, the script checks for Administrator rights. If absent it re-launches itself with `-Verb RunAs`, triggering a UAC prompt. The compiled `.exe` also has an embedded manifest with `requireAdministrator`.

```powershell
$isAdmin = ([Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList (
        "-ExecutionPolicy Bypass -WindowStyle Normal -File `"$PSCommandPath`""
    )
    exit
}
```

### Effect Engine

Effects run on a single `DispatcherTimer`. A `switch` block on `$script:fxType` selects the active effect each tick. All parameters (color, speed) live in `$script:fxParams`.

This design deliberately avoids `.GetNewClosure()` — closures in PowerShell create a dynamic module scope where script-level helper functions (`HSVtoRGB`, `LerpRGB`, etc.) become invisible, causing silent failures.

```
Timer fires every N ms
  └── switch ($script:fxType)
        ├── "Breathing"   → sine-wave brightness on user color
        ├── "Rainbow"     → HSV hue sweep
        ├── "ColorCycle"  → lerp between color and complement
        ├── "Strobe"      → fast on/off
        ├── "Candle"      → randomized warm flicker
        ├── "Police"      → red/black/blue/black phases
        ├── "NeonPulse"   → crossfade neon palette + brightness pulse
        ├── "Sunset"      → crossfade warm palette
        └── "Ocean"       → crossfade cool palette + wave shimmer
```

### Key Functions

| Function | Signature | Purpose |
|---|---|---|
| `Initialize-Clevo` | `()` | Connects to WMI, verifies `SetKBLED` exists |
| `Set-KBLED` | `([uint32]$Arg)` | Sends a raw uint32 command to the hardware |
| `Set-KBColor` | `([int]$R, [int]$G, [int]$B)` | Converts RGB → Clevo byte format, calls `Set-KBLED` |
| `Set-KBBrightness` | `([int]$L)` | Sends brightness command (0-255) |
| `HSVtoRGB` | `([double]$H, [double]$S, [double]$V)` | HSV → RGB hashtable |
| `LerpRGB` | `([hashtable]$A, [hashtable]$B, [double]$T)` | Linear interpolation between two RGB colors |
| `Start-Effect` | `([string]$Type, [hashtable]$Params, [int]$Ms)` | Starts a named effect with params and tick interval |
| `Stop-Effect` | `()` | Stops the timer and clears effect state |
| `Update-ColorUI` | `([int]$R, [int]$G, [int]$B)` | Updates the swatch and hex label in the UI |
| `Debug-Log` | `([string]$Msg)` | Appends a timestamped line to the debug panel |

---

## Building / Recompiling the EXE

If you edit `kb-rgb-control.ps1`, recompile with:

```powershell
# Install ps2exe once
Install-Module ps2exe -Scope CurrentUser

# Compile
Import-Module ps2exe
Invoke-PS2EXE `
    -InputFile  '.\kb-rgb-control.ps1' `
    -OutputFile '.\KB RGB Control.exe' `
    -noConsole `
    -requireAdmin `
    -iconFile   '.\kb-rgb.ico' `
    -title       'KB RGB Control' `
    -description 'Keyboard RGB lighting for Gigabyte G5 MF' `
    -version     '1.0.0.0'
```

---

## Safety

This app **only** uses `CLEVO_GET.SetKBLED` — the same WMI method that Gigabyte Control Center calls internally. It does **not**:

- Write to firmware or BIOS
- Modify the registry
- Access hardware I/O ports directly
- Change any system or driver files

If WMI is unavailable or the call fails, the app logs the error and continues; the UI still animates as a visual preview.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Status shows "WMI not available" | Clevo WMI driver not loaded | Install Gigabyte Control Center or the Clevo driver package once, then you can uninstall GCC |
| UAC prompt appears twice | Script not running from `.exe` path | Use the compiled `.exe` or shortcut — not raw PS from `%USERPROFILE%` |
| Keyboard doesn't change color | Not running as Administrator | Accept the UAC prompt; check `Debug-Log` panel |
| Effects are very slow | Speed slider set too low | Increase Speed slider, or pass higher `-Spd` value |
| Strobe is not visible | Speed too low or brightness too low | Increase both Speed and Bright sliders |
| `Invoke-PS2EXE` fails | `ps2exe` module not installed | Run `Install-Module ps2exe -Scope CurrentUser` |

---

## Known Bugs Fixed

| Bug | Root Cause | Fix Applied |
|---|---|---|
| Effects silently did nothing | `.GetNewClosure()` created closures in a dynamic module scope — `HSVtoRGB`, `LerpRGB` invisible inside | Removed all closures; single `switch`-based tick handler reads `$script:fxType` + `$script:fxParams` |
| Window never appeared | Desktop shortcut used `-WindowStyle Hidden` | Changed to `-WindowStyle Normal` |
| Timer tick action out of scope | `$TickAction` variable not accessible inside timer block | Changed to `$script:currentTick` |
| Sliders didn't update keyboard | Missing `Set-KBColor` call in slider `ValueChanged` events | Added real-time WMI call on slider move |
| Shortcut icon broken | Extra quotes in `.lnk` icon path property | Removed extra quotes |

---

## Extending — Adding a New Effect

1. Add a new `case` to the `switch` block in `Start-Effect` inside `kb-rgb-control.ps1`:

```powershell
"MyEffect" {
    # $elapsed = seconds since effect started
    # $p       = $script:fxParams  (your custom hashtable)
    # $spd     = speed multiplier from slider
    $cr = 128; $cg = 0; $cb = 255
    Set-KBColor $cr $cg $cb
    Update-ColorUI $cr $cg $cb
}
```

2. Add a button in the XAML `UniformGrid`:

```xml
<Button x:Name="btnMyEffect" Content="My Effect" Margin="3" Style="{StaticResource RoundBtn}"/>
```

3. Wire the button in the button-events section:

```powershell
$btnMyEffect = $window.FindName("btnMyEffect")
$btnMyEffect.Add_Click({
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "My Effect  Speed:${spd}x"
    Start-Effect -Type "MyEffect" -Params @{Spd=$spd} -Ms 40
})
```

4. Recompile with `Invoke-PS2EXE` (see above).

---

## License

MIT License — free to use, modify, and distribute. See [LICENSE](LICENSE) for details.

---

## Credits

- **WMI protocol** reverse-engineered from Gigabyte Control Center's WMI calls
- **ps2exe** by MScholtes — [github.com/MScholtes/PS2EXE](https://github.com/MScholtes/PS2EXE)
- Built entirely in PowerShell 5.1 + WPF — zero external runtime dependencies
