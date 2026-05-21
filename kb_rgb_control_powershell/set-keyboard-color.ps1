<#
.SYNOPSIS
    Sets the Gigabyte G5 MF (Clevo) keyboard backlight color to red.

.DESCRIPTION
    This script uses the Clevo WMI interface (CLEVO_GET class) exposed by
    the AcpiBridge.sys driver to set the keyboard backlight color.
    
    This is the SAME interface used by the Gigabyte Control Center GUI.
    It does NOT modify any files, registry, firmware, or drivers.
    
    The SetKBLED method maps to Clevo EC command 0x67.
    Parameter format: 0xZZBBRRGG
      ZZ = Sub-command (F0=Zone 0 color, F4=brightness)
      BB = Blue component (00-FF)
      RR = Red component (00-FF)
      GG = Green component (00-FF)

.NOTES
    Laptop: Gigabyte G5 MF (Clevo single-zone RGB backlight)
    Requires: Administrator privileges
    Safety: Read/write to WMI only - no file/registry/firmware changes
#>

param(
    [ValidateRange(0, 255)]
    [int]$Red = 255,
    
    [ValidateRange(0, 255)]
    [int]$Green = 0,
    
    [ValidateRange(0, 255)]
    [int]$Blue = 0,
    
    [ValidateRange(0, 255)]
    [int]$Brightness = 255
)

# Log output to file so we can verify results
$logFile = "$env:USERPROFILE\set-keyboard-red-log.txt"
Start-Transcript -Path $logFile -Force | Out-Null

function Set-ClevoKBLED {
    param(
        [uint32]$Argument
    )
    
    try {
        $clevoGet = Get-WmiObject -Namespace root\WMI -Class CLEVO_GET -ErrorAction Stop
        Write-Host "  Calling SetKBLED with argument: 0x$($Argument.ToString('X8')) ($Argument)" -ForegroundColor Gray
        $result = $clevoGet.SetKBLED($Argument)
        Write-Host "  WMI returned: $($result | Out-String)" -ForegroundColor Gray
        return $result
    }
    catch {
        Write-Error "Failed to call SetKBLED: $($_.Exception.Message)"
        Write-Error "Make sure you are running as Administrator."
        return $null
    }
}

# --- Safety check: verify the WMI class exists ---
Write-Host "Checking for Clevo WMI interface..." -ForegroundColor Cyan
try {
    $classCheck = [wmiclass]"root\WMI:CLEVO_GET"
    $methods = $classCheck.Methods | Where-Object { $_.Name -eq 'SetKBLED' }
    if (-not $methods) {
        Write-Error "SetKBLED method not found in CLEVO_GET class. Aborting."
        exit 1
    }
    Write-Host "  CLEVO_GET.SetKBLED method found." -ForegroundColor Green
}
catch {
    Write-Error "CLEVO_GET WMI class not found. Is this a Clevo/Gigabyte laptop?"
    exit 1
}

# --- Build UInt32 values safely (PowerShell 5.1 treats hex > 0x7FFFFFFF as negative Int32) ---
# Use [System.Convert] to avoid signed/unsigned overflow issues
function Build-UInt32 {
    param([long]$Zone, [long]$B, [long]$R, [long]$G)
    [uint32]($Zone + ($B * 65536) + ($R * 256) + $G)
}

# --- Step 1: Set brightness ---
# Format: 0xF4_00_00_BB where BB = brightness value
$brightnessArg = Build-UInt32 -Zone 4093640704 -B 0 -R 0 -G $Brightness  # 0xF4000000 = 4093640704
Write-Host "`nStep 1: Setting brightness to $Brightness (0x$($brightnessArg.ToString('X8')))..." -ForegroundColor Cyan

$result = Set-ClevoKBLED -Argument $brightnessArg
if ($null -eq $result) {
    Write-Error "Failed to set brightness. Aborting."
    exit 1
}
Write-Host "  Brightness set successfully." -ForegroundColor Green

# --- Step 2: Set color on Zone 0 ---
# Format: 0xF0_BB_RR_GG (note: Blue-Red-Green byte order, NOT RGB)
# 0xF0000000 = 4026531840
$colorArg = Build-UInt32 -Zone 4026531840 -B $Blue -R $Red -G $Green
Write-Host "Step 2: Setting color to R=$Red G=$Green B=$Blue (0x$($colorArg.ToString('X8')))..." -ForegroundColor Cyan

$result = Set-ClevoKBLED -Argument $colorArg
if ($null -eq $result) {
    Write-Error "Failed to set color. Aborting."
    exit 1
}
Write-Host "  Color set successfully." -ForegroundColor Green

Write-Host "`nKeyboard backlight color changed to R=$Red G=$Green B=$Blue at brightness $Brightness." -ForegroundColor Yellow
Write-Host "Done!" -ForegroundColor Green

Stop-Transcript | Out-Null
