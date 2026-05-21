<#
.SYNOPSIS
    Smooth rainbow color transition for Gigabyte G5 MF (Clevo) keyboard backlight.

.DESCRIPTION
    Continuously sweeps through the full HSV color wheel at full saturation
    and brightness, producing a seamless rainbow gradient effect on the
    single-zone RGB keyboard backlight.

    Uses the same safe WMI interface (CLEVO_GET.SetKBLED) as the Gigabyte
    Control Center GUI. No files, registry, or firmware are modified.

    Press Ctrl+C to stop. The keyboard will remain on whatever color it
    was displaying when you stop.

.PARAMETER CycleDuration
    Time in seconds for one full rainbow cycle (default: 10).

.PARAMETER FrameDelay
    Milliseconds between color updates (default: 50 = ~20 FPS).

.PARAMETER Cycles
    Number of full rainbow cycles to run. 0 = infinite (default: 0).

.PARAMETER Brightness
    Keyboard brightness 0-255 (default: 255).

.PARAMETER Saturation
    Color saturation 0.0-1.0 (default: 1.0). Lower values produce
    pastel/washed-out colors.

.NOTES
    Laptop: Gigabyte G5 MF (Clevo single-zone RGB backlight)
    Requires: Administrator privileges
    Safety: Read/write to WMI only - same as the GUI app
#>

param(
    [double]$CycleDuration = 10,

    [ValidateRange(20, 2000)]
    [int]$FrameDelay = 50,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$Cycles = 0,

    [ValidateRange(0, 255)]
    [int]$Brightness = 255,

    [ValidateRange(0.0, 1.0)]
    [double]$Saturation = 1.0
)

# --- HSV to RGB conversion ---
# H: 0-360, S: 0-1, V: 0-1 -> R,G,B: 0-255
function Convert-HsvToRgb {
    param(
        [double]$H,
        [double]$S,
        [double]$V
    )

    # Normalize hue to 0-360
    $H = $H % 360
    if ($H -lt 0) { $H += 360 }

    $C = $V * $S
    $X = $C * (1 - [Math]::Abs(($H / 60) % 2 - 1))
    $M = $V - $C

    if     ($H -lt 60)  { $r1 = $C; $g1 = $X; $b1 = 0  }
    elseif ($H -lt 120) { $r1 = $X; $g1 = $C; $b1 = 0  }
    elseif ($H -lt 180) { $r1 = 0;  $g1 = $C; $b1 = $X }
    elseif ($H -lt 240) { $r1 = 0;  $g1 = $X; $b1 = $C }
    elseif ($H -lt 300) { $r1 = $X; $g1 = 0;  $b1 = $C }
    else                { $r1 = $C; $g1 = 0;  $b1 = $X }

    @{
        R = [int][Math]::Round(($r1 + $M) * 255)
        G = [int][Math]::Round(($g1 + $M) * 255)
        B = [int][Math]::Round(($b1 + $M) * 255)
    }
}

# --- WMI helpers (same as our other scripts) ---
function Build-UInt32 {
    param([long]$Zone, [long]$B, [long]$R, [long]$G)
    [uint32]($Zone + ($B * 65536) + ($R * 256) + $G)
}

$script:clevoGet = $null
function Set-ClevoKBLED {
    param([uint32]$Argument)
    if ($null -eq $script:clevoGet) {
        $script:clevoGet = Get-WmiObject -Namespace root\WMI -Class CLEVO_GET -ErrorAction Stop
    }
    $script:clevoGet.SetKBLED($Argument) | Out-Null
}

function Set-Color {
    param([int]$R, [int]$G, [int]$B)
    $arg = Build-UInt32 -Zone 4026531840 -B $B -R $R -G $G
    Set-ClevoKBLED -Argument $arg
}

# --- Verify WMI class exists ---
Write-Host "Checking for Clevo WMI interface..." -ForegroundColor Cyan
try {
    $classCheck = [wmiclass]"root\WMI:CLEVO_GET"
    $methods = $classCheck.Methods | Where-Object { $_.Name -eq 'SetKBLED' }
    if (-not $methods) {
        Write-Error "SetKBLED method not found. Aborting."
        exit 1
    }
    Write-Host "  CLEVO_GET.SetKBLED found." -ForegroundColor Green
}
catch {
    Write-Error "CLEVO_GET WMI class not found. Is this a Clevo/Gigabyte laptop?"
    exit 1
}

# --- Set brightness ---
$brightnessArg = Build-UInt32 -Zone 4093640704 -B 0 -R 0 -G $Brightness
Write-Host "Setting brightness to $Brightness..." -ForegroundColor Cyan
Set-ClevoKBLED -Argument $brightnessArg
Write-Host "  Done." -ForegroundColor Green

# --- Calculate timing ---
$stepsPerCycle = [int]($CycleDuration * 1000 / $FrameDelay)
if ($stepsPerCycle -lt 10) { $stepsPerCycle = 10 }
$hueStep = 360.0 / $stepsPerCycle

$cycleLabel = if ($Cycles -eq 0) { "infinite" } else { "$Cycles" }
Write-Host "`nRainbow mode:" -ForegroundColor Yellow
Write-Host "  Cycle duration : ${CycleDuration}s" -ForegroundColor Gray
Write-Host "  Frame delay    : ${FrameDelay}ms (~$([int](1000/$FrameDelay)) FPS)" -ForegroundColor Gray
Write-Host "  Steps per cycle: $stepsPerCycle" -ForegroundColor Gray
Write-Host "  Hue step       : $([Math]::Round($hueStep, 2)) degrees" -ForegroundColor Gray
Write-Host "  Saturation     : $Saturation" -ForegroundColor Gray
Write-Host "  Cycles         : $cycleLabel" -ForegroundColor Gray
Write-Host "`nPress Ctrl+C to stop.`n" -ForegroundColor Cyan

# --- Main loop ---
$cycleCount = 0
$hue = 0.0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameCount = 0

try {
    while ($true) {
        $frameStart = $sw.ElapsedMilliseconds

        # Convert current hue to RGB
        $rgb = Convert-HsvToRgb -H $hue -S $Saturation -V 1.0
        Set-Color -R $rgb.R -G $rgb.G -B $rgb.B

        $frameCount++

        # Advance hue
        $hue += $hueStep
        if ($hue -ge 360.0) {
            $hue -= 360.0
            $cycleCount++

            $elapsed = $sw.Elapsed
            Write-Host "  Cycle $cycleCount complete (elapsed: $($elapsed.ToString('mm\:ss\.f')))" -ForegroundColor DarkGray

            # Check if we've done enough cycles
            if ($Cycles -gt 0 -and $cycleCount -ge $Cycles) {
                Write-Host "`nCompleted $cycleCount cycle(s)." -ForegroundColor Green
                break
            }
        }

        # Throttle to target frame rate (subtract time spent on WMI call)
        $elapsed_ms = $sw.ElapsedMilliseconds - $frameStart
        $sleepTime = $FrameDelay - $elapsed_ms
        if ($sleepTime -gt 0) {
            Start-Sleep -Milliseconds $sleepTime
        }
    }
}
catch {
    # Ctrl+C or other interruption
}
finally {
    $totalElapsed = $sw.Elapsed
    $avgFps = if ($totalElapsed.TotalSeconds -gt 0) { [Math]::Round($frameCount / $totalElapsed.TotalSeconds, 1) } else { 0 }
    Write-Host "`nRainbow stopped." -ForegroundColor Yellow
    Write-Host "  Total frames: $frameCount | Avg FPS: $avgFps | Runtime: $($totalElapsed.ToString('mm\:ss\.f'))" -ForegroundColor Gray
}
