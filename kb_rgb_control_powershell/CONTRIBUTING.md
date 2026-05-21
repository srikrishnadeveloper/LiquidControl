# Contributing to KB RGB Control

Thanks for wanting to improve KB RGB Control! Here's everything you need to know.

---

## Quick Start

1. **Fork** this repository on GitHub
2. **Clone** your fork locally
3. Edit `kb-rgb-control.ps1` — this is the only file you normally need to touch
4. Test your changes (see below)
5. **Submit a pull request** with a clear description of what you changed and why

---

## Project Structure

```
KB RGB Control/
├── kb-rgb-control.ps1       Main GUI — all logic lives here
├── set-keyboard-color.ps1   CLI utility (static color)
├── set-keyboard-rainbow.ps1 CLI utility (rainbow loop)
├── kb-rgb.ico               App icon
└── README.md / CONTRIBUTING.md / LICENSE
```

The compiled `.exe` is **not** checked in to source control. You build it yourself from `kb-rgb-control.ps1`.

---

## Testing Without Compiling

You don't need to recompile to test. Run the script directly:

```powershell
powershell -ExecutionPolicy Bypass -File "kb-rgb-control.ps1"
```

Accept the UAC prompt — the GUI window will open. Changes to the `.ps1` are live on the next run.

---

## Recompiling the EXE

After you're happy with your changes:

```powershell
Install-Module ps2exe -Scope CurrentUser   # once
Import-Module ps2exe
Invoke-PS2EXE `
    -InputFile  '.\kb-rgb-control.ps1' `
    -OutputFile '.\KB RGB Control.exe' `
    -noConsole -requireAdmin `
    -iconFile   '.\kb-rgb.ico' `
    -title       'KB RGB Control' `
    -description 'Keyboard RGB lighting for Gigabyte G5 MF' `
    -version     '1.0.0.0'
```

---

## Adding a New Effect

This is the most common contribution. Three places to touch:

### 1. Add the effect logic — `kb-rgb-control.ps1`, inside the `switch` in `Start-Effect`

```powershell
"MyEffect" {
    # $elapsed  = seconds since effect started (float)
    # $p        = $script:fxParams hashtable (your custom keys)
    # $spd      = speed multiplier (from $p.Spd)
    # Always call both Set-KBColor AND Update-ColorUI so the UI stays in sync
    $cr = 255; $cg = 0; $cb = [int]($elapsed * 50 % 255)
    Set-KBColor $cr $cg $cb
    Update-ColorUI $cr $cg $cb
}
```

Rules:
- Use `$elapsed` for time-based animation — **never** use `Start-Sleep` inside a tick handler
- Always clamp values to 0–255
- Call both `Set-KBColor` (hardware) and `Update-ColorUI` (UI swatch)
- Use `$script:fxRandom` for randomness (already seeded)
- Interval (`-Ms`) guide: 40ms = 25 FPS (smooth), 60ms = 16 FPS (fire/flicker), 30ms = 33 FPS (strobe)

### 2. Add the button — XAML `UniformGrid` in `kb-rgb-control.ps1`

```xml
<Button x:Name="btnMyEffect" Content="My Effect" Margin="3" Style="{StaticResource RoundBtn}"/>
```

### 3. Wire the button click event

```powershell
$btnMyEffect = $window.FindName("btnMyEffect")
$btnMyEffect.Add_Click({
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "My Effect  Speed:${spd}x"
    Start-Effect -Type "MyEffect" -Params @{Spd=$spd} -Ms 40
})
```

---

## Code Style

- Use `$script:` prefix for all variables shared between the timer tick and the rest of the script
- Never use `.GetNewClosure()` on timer `Add_Tick` handlers — script-scope functions become invisible in the resulting dynamic module
- Keep the XAML inline in the heredoc — no external `.xaml` file
- `Debug-Log` for any user-visible status messages
- `try/catch {}` only at the hardware call level (`Set-KBLED`) — let errors propagate up to the tick handler's outer `catch` for logging

---

## Reporting Bugs

Open a GitHub Issue and include:

- Your laptop model (e.g., `Gigabyte G5 MF`, `Metabox Prime-S`, etc.)
- Windows version (`winver`)
- What happened vs. what you expected
- The content of the **debug panel** at the bottom of the app window

---

## Hardware Compatibility Reports

If you've tested on a laptop **other than the Gigabyte G5 MF**, please open an issue or PR to add it to the compatibility table in `README.md`. Include:
- Laptop model
- Whether `CLEVO_GET.SetKBLED` is present (`Get-WmiObject -Namespace root\WMI -Class CLEVO_GET`)
- Whether color and brightness commands work
- Any differences in the command format (if any)
