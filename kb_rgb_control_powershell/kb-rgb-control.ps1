<#
.SYNOPSIS
    KB RGB Control - Real-time keyboard RGB lighting for Gigabyte G5 MF (Clevo).

.DESCRIPTION
    WPF GUI app with 10 animated lighting effects for the Clevo single-zone
    RGB keyboard backlight.  Communicates via WMI CLEVO_GET.SetKBLED — the
    same interface used by Gigabyte Control Center internally.

    Effects run on a DispatcherTimer (no background threads).  All effect
    state lives in $script:fxType / $script:fxParams to avoid the PowerShell
    closure / dynamic-module-scope issue that makes script functions invisible
    inside .GetNewClosure() timer handlers.

.NOTES
    Requires    : Administrator (WMI hardware access)
    Hardware    : Gigabyte G5 MF — any Clevo laptop with CLEVO_GET WMI class
    Dependencies: PowerShell 5.1, WPF (built-in), AcpiBridge.sys driver
    Compile     : Invoke-PS2EXE (see README.md)
    Author      : srik2
    License     : MIT
#>

# ================================================================
#  SELF-ELEVATE TO ADMINISTRATOR
#  WMI CLEVO_GET.SetKBLED requires Admin.  If not elevated, re-launch
#  this script with -Verb RunAs (triggers the UAC prompt), then exit the
#  current non-elevated instance.
# ================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList (
        "-ExecutionPolicy Bypass -WindowStyle Normal -File `"$PSCommandPath`""
    )
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ================================================================
#  HARDWARE — WMI CLEVO_GET interface
#
#  Command encoding (32-bit uint passed to SetKBLED):
#
#    Color    : 0xF0_BB_RR_GG  (sub-cmd F0, byte order: Blue-Red-Green)
#               = 4026531840 + (B*65536) + (R*256) + G
#
#    Brightness: 0xF4_00_00_LL  (sub-cmd F4, level 0-255)
#               = 4093640704 + Level
# ================================================================
$script:clevoGet = $null
$script:hwOk     = $false

function Initialize-Clevo {
    <# Connects to the CLEVO_GET WMI object and verifies SetKBLED exists.
       Sets $script:hwOk to $true on success. #>
    try {
        $script:clevoGet = Get-WmiObject -Namespace root\WMI -Class CLEVO_GET -ErrorAction Stop
        $methods = ([wmiclass]"root\WMI:CLEVO_GET").Methods | Where-Object { $_.Name -eq 'SetKBLED' }
        $script:hwOk = ($null -ne $methods)
    } catch {
        $script:hwOk = $false
    }
}

function Set-KBLED { param([uint32]$Arg)
    <# Sends a raw uint32 command to the keyboard. Silently ignores errors so
       the UI keeps running even when WMI is unavailable. #>
    if ($null -eq $script:clevoGet) { return }
    try { $script:clevoGet.SetKBLED($Arg) | Out-Null } catch {}
}

function Set-KBColor { param([int]$R,[int]$G,[int]$B)
    <# Converts an RGB triplet to the Clevo 0xF0_BB_RR_GG encoding and
       sends it.  Values are clamped to 0-255 before encoding. #>
    $R = [Math]::Max(0,[Math]::Min(255,$R))
    $G = [Math]::Max(0,[Math]::Min(255,$G))
    $B = [Math]::Max(0,[Math]::Min(255,$B))
    [uint32]$arg = [uint32](4026531840 + ($B * 65536) + ($R * 256) + $G)
    Set-KBLED $arg
}

function Set-KBBrightness { param([int]$L)
    <# Sets keyboard backlight brightness.  Level is clamped to 0-255.  The
       WMI sub-command is 0xF4; base value is 0xF4000000 = 4093640704. #>
    $L = [Math]::Max(0,[Math]::Min(255,$L))
    [uint32]$arg = [uint32](4093640704 + $L)
    Set-KBLED $arg
}

# ================================================================
#  COLOR MATH HELPERS
# ================================================================
function HSVtoRGB { param([double]$H,[double]$S,[double]$V)
    <# Converts HSV (H: 0-360, S: 0-1, V: 0-1) to an RGB hashtable
       with keys R, G, B each in the range 0-255. #>
    $H = $H % 360; if ($H -lt 0) { $H += 360 }
    $C = $V * $S; $X = $C * (1 - [Math]::Abs(($H / 60) % 2 - 1)); $M = $V - $C
    if     ($H -lt  60) { $r1=$C; $g1=$X; $b1=0 }
    elseif ($H -lt 120) { $r1=$X; $g1=$C; $b1=0 }
    elseif ($H -lt 180) { $r1=0;  $g1=$C; $b1=$X }
    elseif ($H -lt 240) { $r1=0;  $g1=$X; $b1=$C }
    elseif ($H -lt 300) { $r1=$X; $g1=0;  $b1=$C }
    else                { $r1=$C; $g1=0;  $b1=$X }
    @{ R=[int][Math]::Round(($r1+$M)*255); G=[int][Math]::Round(($g1+$M)*255); B=[int][Math]::Round(($b1+$M)*255) }
}

function LerpRGB { param([hashtable]$A,[hashtable]$B,[double]$T)
    <# Linear interpolation between two RGB hashtables.  T=0 returns A,
       T=1 returns B, values between give a smooth blend. #>
    @{ R=[int]($A.R+($B.R-$A.R)*$T); G=[int]($A.G+($B.G-$A.G)*$T); B=[int]($A.B+($B.B-$A.B)*$T) }
}

# ================================================================
#  EFFECT ENGINE
#
#  Design: a single DispatcherTimer fires every N ms.  The Add_Tick
#  handler reads $script:fxType and $script:fxParams (set by Start-Effect)
#  via a switch statement — NO closures, NO .GetNewClosure().
#
#  Why no closures?  PowerShell closures create a dynamic module scope
#  where script-level functions (HSVtoRGB, LerpRGB, Set-KBColor, etc.)
#  are not visible, causing all effects to silently fail.
#
#  $script:fxRandom is shared so Candle flicker is seeded once and
#  consistent across frames.
# ================================================================
$script:timer     = $null
$script:running   = $false
$script:fxType    = ""        # name of the active effect, or "" for none
$script:fxParams  = @{}       # parameters hashtable (color, speed, etc.)
$script:fxStart   = [DateTime]::Now   # timestamp of last Start-Effect call
$script:fxRandom  = New-Object System.Random
$script:tickCount = 0         # total ticks since last Start-Effect

function Stop-Effect {
    <# Stops the DispatcherTimer and resets all effect state. #>
    $script:running   = $false
    $script:fxType    = ""
    $script:tickCount = 0
    if ($script:timer) { $script:timer.Stop(); $script:timer = $null }
}

function Start-Effect { param([string]$Type, [hashtable]$Params=@{}, [int]$Ms=40)
    <#
    .PARAMETER Type    Effect name matching a case in the switch block below.
    .PARAMETER Params  Hashtable of effect-specific values.  Must include
                       'Spd' (float speed multiplier).  Color effects also
                       pass R/G/B; ColorCycle passes C1/C2 hashtables.
    .PARAMETER Ms      Timer interval in milliseconds (tick rate).
                       40ms = ~25 FPS.  Use 30ms for strobe/police,
                       60ms for candle, 50ms for sunset/ocean.
    #>
    Stop-Effect
    $script:fxType   = $Type
    $script:fxParams = $Params
    $script:fxStart  = [DateTime]::Now
    $script:running  = $true
    $script:timer    = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds($Ms)
    $script:timer.Add_Tick({
        if (-not $script:running) { return }
        $script:tickCount++
        $elapsed = ([DateTime]::Now - $script:fxStart).TotalSeconds
        $p       = $script:fxParams
        $spd     = if ($p.ContainsKey('Spd')) { $p.Spd } else { 1.0 }

        try {
            switch ($script:fxType) {

                "Breathing" {
                    $v = ([Math]::Sin($elapsed * $spd * [Math]::PI) + 1) / 2
                    $cr = [int]($p.R * $v); $cg = [int]($p.G * $v); $cb = [int]($p.B * $v)
                    Set-KBColor $cr $cg $cb
                    Update-ColorUI $cr $cg $cb
                }

                "Rainbow" {
                    $h = ($elapsed * 36 * $spd) % 360
                    $c = HSVtoRGB $h 1 1
                    Set-KBColor $c.R $c.G $c.B
                    Update-ColorUI $c.R $c.G $c.B
                }

                "ColorCycle" {
                    $t  = ([Math]::Sin($elapsed * $spd * [Math]::PI) + 1) / 2
                    $c1 = $p.C1; $c2 = $p.C2
                    $c  = LerpRGB $c1 $c2 $t
                    Set-KBColor $c.R $c.G $c.B
                    Update-ColorUI $c.R $c.G $c.B
                }

                "Strobe" {
                    $on = ([Math]::Sin($elapsed * $spd * [Math]::PI * 4)) -gt 0
                    if ($on) {
                        Set-KBColor $p.R $p.G $p.B
                        Update-ColorUI $p.R $p.G $p.B
                    } else {
                        Set-KBColor 0 0 0
                        Update-ColorUI 0 0 0
                    }
                }

                "Candle" {
                    $f  = $script:fxRandom.NextDouble() * 0.4 + 0.6
                    $rs = $script:fxRandom.NextDouble() * 30
                    $cr = [int](255*$f); $cg = [int]((100+$rs)*$f); $cb = [int](20*$f)
                    Set-KBColor $cr $cg $cb
                    Update-ColorUI $cr $cg $cb
                }

                "Police" {
                    $phase = [int]($elapsed * 4 * $spd) % 4
                    switch ($phase) {
                        0 { Set-KBColor 255 0 0;   Update-ColorUI 255 0 0 }
                        1 { Set-KBColor 0 0 0;     Update-ColorUI 0 0 0 }
                        2 { Set-KBColor 0 0 255;   Update-ColorUI 0 0 255 }
                        3 { Set-KBColor 0 0 0;     Update-ColorUI 0 0 0 }
                    }
                }

                "NeonPulse" {
                    $cols = @(
                        @{R=255;G=0;B=255}, @{R=0;G=255;B=255}, @{R=255;G=255;B=0},
                        @{R=255;G=0;B=100}, @{R=0;G=255;B=100}, @{R=100;G=0;B=255}
                    )
                    $n   = $cols.Count
                    $pos = ($elapsed * $spd * 0.5) % $n
                    $i   = [int][Math]::Floor($pos)
                    $t   = $pos - $i
                    $j   = ($i + 1) % $n
                    $c   = LerpRGB $cols[$i] $cols[$j] $t
                    $pulse = ([Math]::Sin($elapsed * $spd * [Math]::PI * 3) + 1) / 2 * 0.3 + 0.7
                    $cr = [int]($c.R*$pulse); $cg = [int]($c.G*$pulse); $cb = [int]($c.B*$pulse)
                    Set-KBColor $cr $cg $cb
                    Update-ColorUI $cr $cg $cb
                }

                "Sunset" {
                    $cols = @(
                        @{R=255;G=60;B=0}, @{R=255;G=120;B=0}, @{R=255;G=180;B=40},
                        @{R=200;G=50;B=30}, @{R=180;G=30;B=60}, @{R=255;G=80;B=20}
                    )
                    $n   = $cols.Count
                    $pos = ($elapsed * $spd * 0.3) % $n
                    $i   = [int][Math]::Floor($pos)
                    $t   = $pos - $i
                    $j   = ($i + 1) % $n
                    $c   = LerpRGB $cols[$i] $cols[$j] $t
                    Set-KBColor $c.R $c.G $c.B
                    Update-ColorUI $c.R $c.G $c.B
                }

                "Ocean" {
                    $cols = @(
                        @{R=0;G=50;B=180}, @{R=0;G=150;B=200}, @{R=0;G=200;B=200},
                        @{R=0;G=100;B=160}, @{R=20;G=60;B=140}
                    )
                    $n   = $cols.Count
                    $pos = ($elapsed * $spd * 0.3) % $n
                    $i   = [int][Math]::Floor($pos)
                    $t   = $pos - $i
                    $j   = ($i + 1) % $n
                    $c   = LerpRGB $cols[$i] $cols[$j] $t
                    $w   = ([Math]::Sin($elapsed * $spd * [Math]::PI * 0.8) + 1) / 2 * 0.2 + 0.8
                    $cr = [int]($c.R*$w); $cg = [int]($c.G*$w); $cb = [int]($c.B*$w)
                    Set-KBColor $cr $cg $cb
                    Update-ColorUI $cr $cg $cb
                }
            }

            # Update debug log every 25 ticks (~1 sec) to avoid flooding
            if ($script:tickCount % 25 -eq 0) {
                $hex = $txtHex.Text
                Debug-Log "[tick $($script:tickCount)] $($script:fxType) | $hex | elapsed=$([Math]::Round($elapsed,1))s"
            }

        } catch {
            Debug-Log "ERROR in tick: $($_.Exception.Message)"
        }
    })
    $script:timer.Start()
    Debug-Log "Effect started: $Type (interval=${Ms}ms, speed=$($Params.Spd))"
}

# ================================================================
#  UI  — WPF XAML definition
#
#  Theme  : dark (#111111 background), white text, Segoe UI
#  Layout : 7-row Grid inside 620×640 window
#    Row 0: title + status text
#    Row 1: color swatch (live preview) + hex label
#    Row 2: R/G/B sliders + Speed + Bright sliders
#    Row 3: active-effect label
#    Row 4: UniformGrid of 10 effect buttons (3 columns)
#    Row 5: STOP button
#    Row 6: debug log panel (Consolas, green-on-black)
#
#  Styles: RoundBtn (dark, rounded), StopBtn (red-tinted, rounded)
# ================================================================
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="KB RGB Control"
    Width="620" Height="640"
    WindowStartupLocation="CenterScreen"
    ResizeMode="CanMinimize"
    Background="#111111"
    FontFamily="Segoe UI">

  <Window.Resources>
    <!-- Rounded dark button style -->
    <Style x:Key="RoundBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#222222" BorderBrush="#444444" BorderThickness="1"
                    CornerRadius="6" Padding="4,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#333333"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#666666"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#444444"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Stop button style -->
    <Style x:Key="StopBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#441111" BorderBrush="#663333" BorderThickness="1"
                    CornerRadius="6" Padding="4,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#662222"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#884444"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#883333"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Title + Status -->
    <StackPanel Grid.Row="0" Margin="0,0,0,14">
      <TextBlock Text="KB RGB Control" FontSize="20" FontWeight="Bold" Foreground="White"/>
      <TextBlock x:Name="txtStatus" Text="Initializing..." FontSize="11" Foreground="Gray" Margin="0,2,0,0"/>
    </StackPanel>

    <!-- Color preview (rounded) -->
    <Border Grid.Row="1" Height="44" Margin="0,0,0,14" CornerRadius="8"
            BorderBrush="#333333" BorderThickness="1">
      <Border.Background>
        <SolidColorBrush x:Name="swatchBrush" Color="#FF0000"/>
      </Border.Background>
      <TextBlock x:Name="txtHex" Text="#FF0000" FontSize="14" FontWeight="Bold"
                 Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>

    <!-- Sliders -->
    <Grid Grid.Row="2" Margin="0,0,0,10">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="8"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="56"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="40"/>
      </Grid.ColumnDefinitions>

      <TextBlock Grid.Row="0" Text="Red" Foreground="#FF6666" VerticalAlignment="Center" FontSize="12"/>
      <Slider Grid.Row="0" Grid.Column="1" x:Name="slR" Minimum="0" Maximum="255" Value="255"
              VerticalAlignment="Center" Margin="6,3"/>
      <TextBlock Grid.Row="0" Grid.Column="2" x:Name="lblR" Text="255" Foreground="White"
                 VerticalAlignment="Center" HorizontalAlignment="Right" FontSize="12"/>

      <TextBlock Grid.Row="1" Text="Green" Foreground="#66FF66" VerticalAlignment="Center" FontSize="12"/>
      <Slider Grid.Row="1" Grid.Column="1" x:Name="slG" Minimum="0" Maximum="255" Value="0"
              VerticalAlignment="Center" Margin="6,3"/>
      <TextBlock Grid.Row="1" Grid.Column="2" x:Name="lblG" Text="0" Foreground="White"
                 VerticalAlignment="Center" HorizontalAlignment="Right" FontSize="12"/>

      <TextBlock Grid.Row="2" Text="Blue" Foreground="#6688FF" VerticalAlignment="Center" FontSize="12"/>
      <Slider Grid.Row="2" Grid.Column="1" x:Name="slB" Minimum="0" Maximum="255" Value="0"
              VerticalAlignment="Center" Margin="6,3"/>
      <TextBlock Grid.Row="2" Grid.Column="2" x:Name="lblB" Text="0" Foreground="White"
                 VerticalAlignment="Center" HorizontalAlignment="Right" FontSize="12"/>

      <!-- spacer row 3 -->

      <TextBlock Grid.Row="4" Text="Speed" Foreground="#999999" VerticalAlignment="Center" FontSize="11"/>
      <Slider Grid.Row="4" Grid.Column="1" x:Name="slSpeed" Minimum="0.2" Maximum="4.0" Value="1.0"
              VerticalAlignment="Center" Margin="6,3"/>
      <TextBlock Grid.Row="4" Grid.Column="2" x:Name="lblSpeed" Text="1.0x" Foreground="#999999"
                 VerticalAlignment="Center" HorizontalAlignment="Right" FontSize="11"/>

      <TextBlock Grid.Row="5" Text="Bright" Foreground="#999999" VerticalAlignment="Center" FontSize="11"/>
      <Slider Grid.Row="5" Grid.Column="1" x:Name="slBright" Minimum="10" Maximum="255" Value="255"
              VerticalAlignment="Center" Margin="6,3"/>
      <TextBlock Grid.Row="5" Grid.Column="2" x:Name="lblBright" Text="255" Foreground="#999999"
                 VerticalAlignment="Center" HorizontalAlignment="Right" FontSize="11"/>
    </Grid>

    <!-- Active effect label -->
    <TextBlock Grid.Row="3" x:Name="txtActive" Text="No effect active" Foreground="Gray"
               FontSize="11" Margin="0,2,0,8"/>

    <!-- Effect buttons -->
    <UniformGrid Grid.Row="4" Columns="3" Margin="0,0,0,8">
      <Button x:Name="btnStatic"     Content="Static"       Margin="3" Style="{StaticResource RoundBtn}"/>
      <Button x:Name="btnBreathing"  Content="Breathing"    Margin="3" Style="{StaticResource RoundBtn}"/>
      <Button x:Name="btnRainbow"    Content="Rainbow"      Margin="3" Style="{StaticResource RoundBtn}"/>
      <Button x:Name="btnColorCycle" Content="Color Cycle"  Margin="3" Style="{StaticResource RoundBtn}"/>
      <Button x:Name="btnStrobe"     Content="Strobe"       Margin="3" Style="{StaticResource RoundBtn}"/>
      <Button x:Name="btnCandle"     Content="Candle"       Margin="3" Style="{StaticResource RoundBtn}"/>
      <Button x:Name="btnPolice"     Content="Police"       Margin="3" Style="{StaticResource RoundBtn}"/>
      <Button x:Name="btnNeon"       Content="Neon Pulse"   Margin="3" Style="{StaticResource RoundBtn}"/>
      <Button x:Name="btnSunset"     Content="Sunset"       Margin="3" Style="{StaticResource RoundBtn}"/>
      <Button x:Name="btnOcean"      Content="Ocean"        Margin="3" Style="{StaticResource RoundBtn}"/>
    </UniformGrid>

    <!-- Stop button -->
    <Button Grid.Row="5" x:Name="btnStop" Content="STOP" Height="38"
            Margin="0,0,0,8" Style="{StaticResource StopBtn}"/>

    <!-- Debug log panel -->
    <Border Grid.Row="6" CornerRadius="6" BorderBrush="#333333" BorderThickness="1"
            Background="#0A0A0A" Height="90">
      <ScrollViewer x:Name="debugScroll" VerticalScrollBarVisibility="Auto" Margin="4">
        <TextBlock x:Name="txtDebug" Text="" FontSize="10" FontFamily="Consolas"
                   Foreground="#66FF66" TextWrapping="Wrap"/>
      </ScrollViewer>
    </Border>
  </Grid>
</Window>
'@

# ================================================================
#  LOAD UI
# ================================================================
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$txtStatus   = $window.FindName("txtStatus")
$txtActive   = $window.FindName("txtActive")
$swatchBrush = $window.FindName("swatchBrush")
$txtHex      = $window.FindName("txtHex")
$txtDebug    = $window.FindName("txtDebug")
$debugScroll = $window.FindName("debugScroll")

$slR      = $window.FindName("slR");      $lblR      = $window.FindName("lblR")
$slG      = $window.FindName("slG");      $lblG      = $window.FindName("lblG")
$slB      = $window.FindName("slB");      $lblB      = $window.FindName("lblB")
$slSpeed  = $window.FindName("slSpeed");  $lblSpeed  = $window.FindName("lblSpeed")
$slBright = $window.FindName("slBright"); $lblBright = $window.FindName("lblBright")

$btnStatic     = $window.FindName("btnStatic")
$btnBreathing  = $window.FindName("btnBreathing")
$btnRainbow    = $window.FindName("btnRainbow")
$btnColorCycle = $window.FindName("btnColorCycle")
$btnStrobe     = $window.FindName("btnStrobe")
$btnCandle     = $window.FindName("btnCandle")
$btnPolice     = $window.FindName("btnPolice")
$btnNeon       = $window.FindName("btnNeon")
$btnSunset     = $window.FindName("btnSunset")
$btnOcean      = $window.FindName("btnOcean")
$btnStop       = $window.FindName("btnStop")

# ================================================================
#  DEBUG LOG  — timestamped ring buffer, displayed in the UI panel
# ================================================================
$script:debugLines = @()
function Debug-Log { param([string]$Msg)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $script:debugLines += "[$ts] $Msg"
    # Keep last 50 lines
    if ($script:debugLines.Count -gt 50) {
        $script:debugLines = $script:debugLines[-50..-1]
    }
    $txtDebug.Text = $script:debugLines -join "`n"
    $debugScroll.ScrollToEnd()
}

# ================================================================
#  UI HELPERS
# ================================================================
function Update-ColorUI { param([int]$R,[int]$G,[int]$B)
    <# Updates the color swatch background and the hex label.  Called by
       both slider events (live preview) and effect tick handlers. #>
    $R = [Math]::Max(0,[Math]::Min(255,$R))
    $G = [Math]::Max(0,[Math]::Min(255,$G))
    $B = [Math]::Max(0,[Math]::Min(255,$B))
    $hex = "#{0:X2}{1:X2}{2:X2}" -f $R,$G,$B
    try { $swatchBrush.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($hex) } catch {}
    $txtHex.Text = $hex
}

# ================================================================
#  INIT HARDWARE  — must run after UI is loaded so Debug-Log works
# ================================================================
Initialize-Clevo
if ($script:hwOk) {
    Set-KBBrightness 255
    $txtStatus.Text = "Connected - Keyboard ready (Admin)"
    $txtStatus.Foreground = [System.Windows.Media.Brushes]::LimeGreen
    Debug-Log "WMI connected: CLEVO_GET.SetKBLED available"
} else {
    $txtStatus.Text = "WMI not available - UI preview only"
    $txtStatus.Foreground = [System.Windows.Media.Brushes]::Orange
    Debug-Log "WMI not available (effects will animate in UI only)"
}

Debug-Log "Admin: $isAdmin | HW: $($script:hwOk) | Ready"

# ================================================================
#  SLIDER EVENTS
#  R/G/B: always update the UI swatch; also set hardware when no
#         effect is active (so manual color changes take effect live).
#  Speed: updates the label only — takes effect on the NEXT effect start.
#  Bright: always sends to hardware immediately.
# ================================================================
$slR.Add_ValueChanged({
    $r=[int]$slR.Value; $lblR.Text=$r
    Update-ColorUI $r ([int]$slG.Value) ([int]$slB.Value)
    if (-not $script:running) { Set-KBColor $r ([int]$slG.Value) ([int]$slB.Value) }
})
$slG.Add_ValueChanged({
    $g=[int]$slG.Value; $lblG.Text=$g
    Update-ColorUI ([int]$slR.Value) $g ([int]$slB.Value)
    if (-not $script:running) { Set-KBColor ([int]$slR.Value) $g ([int]$slB.Value) }
})
$slB.Add_ValueChanged({
    $b=[int]$slB.Value; $lblB.Text=$b
    Update-ColorUI ([int]$slR.Value) ([int]$slG.Value) $b
    if (-not $script:running) { Set-KBColor ([int]$slR.Value) ([int]$slG.Value) $b }
})
$slSpeed.Add_ValueChanged({ $lblSpeed.Text = "{0:F1}x" -f $slSpeed.Value })
$slBright.Add_ValueChanged({
    $v=[int]$slBright.Value; $lblBright.Text=$v; Set-KBBrightness $v
    Debug-Log "Brightness: $v"
})

# ================================================================
#  EFFECT BUTTON CLICK HANDLERS
#  Each handler reads the current slider values and calls Start-Effect.
#  No state is captured in closures — all values are passed explicitly
#  via the $Params hashtable so the timer tick sees them in $script:fxParams.
# ================================================================
$btnStatic.Add_Click({
    $r=[int]$slR.Value; $g=[int]$slG.Value; $b=[int]$slB.Value
    Stop-Effect
    Set-KBColor $r $g $b
    Update-ColorUI $r $g $b
    $txtActive.Text = "Static  R:$r G:$g B:$b"
    Debug-Log "Static color: R=$r G=$g B=$b"
})

$btnBreathing.Add_Click({
    $r=[int]$slR.Value; $g=[int]$slG.Value; $b=[int]$slB.Value
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "Breathing  R:$r G:$g B:$b  Speed:${spd}x"
    Start-Effect -Type "Breathing" -Params @{R=$r; G=$g; B=$b; Spd=$spd} -Ms 40
})

$btnRainbow.Add_Click({
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "Rainbow  Speed:${spd}x"
    Start-Effect -Type "Rainbow" -Params @{Spd=$spd} -Ms 40
})

$btnColorCycle.Add_Click({
    $r=[int]$slR.Value; $g=[int]$slG.Value; $b=[int]$slB.Value
    $spd = [Math]::Round($slSpeed.Value, 2)
    $c1=@{R=$r;G=$g;B=$b}; $c2=@{R=(255-$r);G=(255-$g);B=(255-$b)}
    $txtActive.Text = "Color Cycle  Speed:${spd}x"
    Start-Effect -Type "ColorCycle" -Params @{C1=$c1; C2=$c2; Spd=$spd} -Ms 40
})

$btnStrobe.Add_Click({
    $r=[int]$slR.Value; $g=[int]$slG.Value; $b=[int]$slB.Value
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "Strobe  R:$r G:$g B:$b  Speed:${spd}x"
    Start-Effect -Type "Strobe" -Params @{R=$r; G=$g; B=$b; Spd=$spd} -Ms 30
})

$btnCandle.Add_Click({
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "Candle Flicker"
    Start-Effect -Type "Candle" -Params @{Spd=$spd} -Ms 60
})

$btnPolice.Add_Click({
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "Police  Speed:${spd}x"
    Start-Effect -Type "Police" -Params @{Spd=$spd} -Ms 30
})

$btnNeon.Add_Click({
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "Neon Pulse  Speed:${spd}x"
    Start-Effect -Type "NeonPulse" -Params @{Spd=$spd} -Ms 40
})

$btnSunset.Add_Click({
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "Sunset Glow  Speed:${spd}x"
    Start-Effect -Type "Sunset" -Params @{Spd=$spd} -Ms 50
})

$btnOcean.Add_Click({
    $spd = [Math]::Round($slSpeed.Value, 2)
    $txtActive.Text = "Ocean Wave  Speed:${spd}x"
    Start-Effect -Type "Ocean" -Params @{Spd=$spd} -Ms 50
})

$btnStop.Add_Click({
    Stop-Effect
    Set-KBColor 0 0 0
    $txtActive.Text = "Stopped"
    Update-ColorUI 0 0 0
    Debug-Log "Effect stopped, keyboard off"
})

# ================================================================
#  LAUNCH  — wire window close handler, seed UI, show modal dialog
# ================================================================
$window.Add_Closed({
    Stop-Effect
    Debug-Log "Window closing, effect stopped"
})

Update-ColorUI 255 0 0
Debug-Log "UI loaded, ready"
$window.ShowDialog() | Out-Null
