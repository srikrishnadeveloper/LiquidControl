# LiquidControl: Ultimate Clevo/Gigabyte WMI Tuning Suite

**An ultra-lightweight, hardware-native, and zero-dependency cooling and single-zone keyboard RGB control suite for Gigabyte G5 MF and all compatible Clevo-based laptop platforms.**

LiquidControl communicates directly with your laptop's low-level **Embedded Controller (EC)** through the native ACPI firmware via the **WMI (Windows Management Instrumentation) CLEVO_GET interface**. By utilizing native system hooks, it operates with **near-zero CPU and memory footprint**, completely replacing the heavy, resource-intensive, and often bloated OEM background software (such as Gigabyte Control Center).

---

# Repository Contents

This repository represents a unified, complete developer and power-user toolkit:
1. **`LiquidControl` (Flutter Dashboard):** A beautiful, glassmorphic dark-theme desktop dashboard featuring **direct drag-and-drop dual fan curve controls**, real-time polling analytics, and a split side-by-side keyboard backlight mixer with 10 math-driven animated effects.
2. **`kb_rgb_control_powershell` (PowerShell WPF CLI & GUI):** A super lightweight, lightning-fast PowerShell WPF app that wraps the same low-level keyboard lighting API into a standalone Windows `.exe` with zero installation required, perfect for running in the background or embedding in startup scripts.

---

# 1. Reverse Engineering the Clevo WMI Class

Developing custom hardware controllers for laptops requires understanding how modern operating systems communicate with motherboard firmware. On Windows, this bridge is typically established via **WMI (Windows Management Instrumentation)** which maps motherboard ACPI namespaces directly into the OS namespace.

### Step 1: Identifying the ACPI WMI Interface
Hardware vendors like Clevo define a dedicated ACPI device in their BIOS DSDT (Differentiated System Description Table) that acts as a WMI mapper. This device usually contains the `_WDG` (WMI Data Block) evaluation method. 
The WMI mapper binds a unique Windows GUID to an internal ACPI method. On Clevo motherboards, the core GUID used for fan and lighting queries is:
* **GUID:** `7267DE40-1723-11D1-ABE9-08002B30309D` (evaluates to the ACPI class **`CLEVO_GET`** under the `root\WMI` namespace).

### Step 2: Extracting BIOS ACPI Tables (DSDT)
To discover how the vendor mapped these calls internally:
1. Use utility tools like **RW-Everything** (Read/Write Everything) or `acpidump.exe` to dump the motherboard's raw DSDT ACPI table.
2. Decompile the dumped table into readable ASL (ACPI Source Language) using the Intel ACPI Compiler (`iasl.exe`):
   ```bash
   iasl -d dsdt.dat
   ```
3. Search the resulting `.dsl` file for the string `CLEVO` or `WDG` to locate the method block. You will find that methods like `Fan1Info` or `SetKBLED` are mapped to direct memory-mapped physical I/O ports or EC registers:
   ```asl
   // Sample decompiled ACPI mapping
   Method (WMAK, 3, Serialized) {
       If (LEqual (Arg1, 0xF0)) { // Sub-command 0xF0 = LED Color
           Store (Arg2, EC_DATA_REGISTER)
           Notify (\_SB.PCI0.LPCB.EC, 0x90) // Triggers physical Embedded Controller update
       }
   }
   ```

### Step 3: Discovering Exposed Methods on Windows
Once you know the class name is `CLEVO_GET`, you can run an elevated PowerShell prompt to query the WMI class and fetch all exposed hardware methods:
```powershell
# Get all methods exposed by the Clevo WMI class
([wmiclass]"root\WMI:CLEVO_GET").Methods | Select-Object Name, Origin
```
On compatible Gigabyte/Clevo laptops, this will return:
* `Fan1Info` (Read-only: returns CPU temperature, duty, and maximum duty)
* `Fan2Info` (Read-only: returns GPU temperature, duty, and maximum duty)
* `GetFan12RPM` (Read-only: returns raw fan tachometer periods)
* `SetFanDuty` (Write-only: sets manual fan duty)
* `SetFanAutoDuty` (Write-only: toggles EC auto fan curve vs manual duty)
* `SetKBLED` (Write-only: packs RGB color coordinates and brightness)

---

# 2. Keyboard RGB Backlight Specification

The Clevo keyboard backlight is controlled by writing packed 32-bit integers to the WMI method `SetKBLED`. It supports single-zone RGB backlighting.

### A. Color Command Encoding (Sub-command `0xF0`)
* **WMI Command:** `SetKBLED(uint32)`
* **Big-Endian Hex Format:** `0xF0_BB_RR_GG`
  * `F0` = Sub-command prefix for Zone 0 lighting
  * `BB` = 8-bit Blue brightness (`00` to `FF`)
  * `RR` = 8-bit Red brightness (`00` to `FF`)
  * `GG` = 8-bit Green brightness (`00` to `FF`)
* **Critical Discovery:** Clevo maps color in **Blue-Red-Green (BRG)** byte order, rather than standard RGB or BGR.

#### The Mathematical Encoding Formula:
$$\text{WmiArgument} = 4026531840 + (\text{Blue} \times 65536) + (\text{Red} \times 256) + \text{Green}$$
*(Where $4026531840$ represents the `0xF0000000` prefix offset).*

**Example (Pure Magenta: R=255, G=0, B=255):**
$$\text{WmiArgument} = 4026531840 + (255 \times 65536) + (255 \times 256) + 0 = 4043313920 \quad (\text{Hex: } \texttt{0xF101FF00})$$

### B. Backlight Brightness (Sub-command `0xF4`)
* **Big-Endian Hex Format:** `0xF4_00_00_LL`
  * `F4` = Sub-command prefix for Brightness
  * `LL` = 8-bit Brightness level (`0A` / `10` up to `FF` / `255`)

#### The Mathematical Brightness Formula:
$$\text{WmiArgument} = 4093640704 + \text{Level}$$
*(Where $4093640704$ represents the `0xF4000000` prefix offset).*

### C. Direct PowerShell Core Call (No background loops)
```powershell
# Elevated PowerShell
$wmi = Get-WmiObject -Namespace root\WMI -Class CLEVO_GET

# 1. Set Brightness to Full (255)
$brightArg = [uint32](4093640704 + 255)
$wmi.SetKBLED($brightArg)

# 2. Set Backlight Color to pure Cyan (R=0, G=255, B=255)
$colorArg = [uint32](4026531840 + (255 * 65536) + (0 * 256) + 255)
$wmi.SetKBLED($colorArg)
```

---

# 3. Fan Speed Monitoring & Manual Control Loop

The fan system on Gigabyte/Clevo motherboards comprises dual physical fans (CPU Fan 1 and GPU Fan 2) governed by the motherboard's Embedded Controller (EC).

### A. Live Sensor Reading
To extract live temperature, current EC duty cycles, and tachometer speeds, LiquidControl batches reads to the WMI fields.

* **Temperatures & Duties:** `Fan1Info` and `Fan2Info` return packed 32-bit integers.
  * **Temperature (°C):** `(val >> 16) & 0xFF`
  * **Duty Cycle (%):** `(val >> 8) & 0xFF`
  * **Max Duty:** `val & 0xFF`
* **Physical RPM Calculation:** `GetFan12RPM` returns a packed 32-bit integer containing tachometer registers.
  * **CPU Fan RPM:** `((val >> 16) & 0xFFFF) * 16`
  * **GPU Fan RPM:** `(val & 0xFFFF) * 16`
  * *Note: The physical multiplier for G5 Glevo EC registers is exactly `16`. Older platforms used `8` or `30`, but modern ones use `16` to accurately scale RPM readings up to ~6200 RPM.*

### B. Overriding the Automatic Cooling Loop
Modern laptops implement an internal automatic control loop inside the EC that continuously evaluates temperature tables and rewrites fan duty registers. If you write directly to `SetFanDuty`, the EC's automatic loop will overwrite your values within milliseconds, causing the speed override to fail.

To assert manual control, you must execute the following protocol sequence:
1. **Disengage EC Auto Loop:** Write `1` to `SetFanAutoDuty`. This commands the EC to freeze its automatic evaluation cycle and hand duty register overrides over to WMI.
2. **Apply Manual Duty Cycle:** Write a duty percentage (`20` to `100`) to `SetFanDuty`. The EC will immediately scale the PWM duty cycle for both fans to match your target.
3. **Re-engage EC Auto Loop:** When returning the system to default states or closing the app, write `0` to `SetFanAutoDuty`. The EC will instantly resume automatic temperature tracking.

---

# 4. Interactive Drag-and-Drop Curve Mathematics

LiquidControl features a high-fidelity, interactive vector canvas in its **Fan Control** tab that allows you to configure temperature-to-duty curves simply by clicking and dragging nodes.

```
       100% ┼─────────────────────────────────────────● (Pt 4: 100°C, Fixed)
            │                                     /
            │                               ● (Pt 3: Draggable)
  Fan Speed │                           /
   (Duty)   │                     ● (Pt 2: Draggable)
            │                 /
        20% ┼───● (Pt 1: 30°C, Fixed Temp)
            │
            └─┼───────────────────┼─────────────────┼───
             30°C                60°C              100°C
                             Temperature
```

### Constraints and Crossover Protection:
Both CPU and GPU fan curves are configured with exactly **4 nodes** (Start Node, 2 Adjustable Middle Nodes, and End Node) for a highly simplified yet extremely precise curve:
1. **Node 0 (Start):** Locked at $30^\circ\text{C}$ on the X-axis. You can drag its duty value vertically.
2. **Node 3 (End):** Locked at $100^\circ\text{C}$ on the X-axis. You can drag its duty value vertically.
3. **Nodes 1 and 2 (Middle):** Fully draggable on both the X-axis (Temperature) and Y-axis (Duty).
4. **Crossover Protection:** To prevent curves from looping backwards or collapsing, each node is mathematically bounded by its neighbors:
   $$\text{Temp}_{i} \in \left[ \text{Temp}_{i-1} + 2, \ \text{Temp}_{i+1} - 2 \right]$$

### Live Interpolation Algorithm:
When the control loop is running in Curve mode, LiquidControl queries the real-time sensor temperature and interpolates the corresponding fan duty cycle using **linear interpolation (lerp)** between the surrounding nodes:
$$\text{Duty} = \text{Duty}_i + \left( \frac{\text{Temp} - \text{Temp}_i}{\text{Temp}_{i+1} - \text{Temp}_i} \right) \times \left( \text{Duty}_{i+1} - \text{Duty}_i \right)$$

---

# 5. Designing Math-Driven Lighting Animations

To avoid heavy background thread spawning, LiquidControl runs all animated backlighting effects inside a lightweight, highly efficient periodic loop driven by a single system clock timer (firing every 40ms, achieving a solid 25 FPS). All animations are evaluated using time-elapsed mathematical formulas:

1. **Breathing:** Uses a sine-wave function of elapsed seconds ($t$) and user speed multiplier ($s$) to oscillate brightness smoothly:
   $$\text{Brightness}(t) = \frac{\sin(t \cdot s \cdot \pi) + 1}{2}$$
2. **Rainbow Cycle:** Maps the elapsed time directly to the HSV hue angle ($0$ to $360^\circ$) to cycle the spectrum smoothly:
   $$\text{Hue}(t) = (t \cdot 36 \cdot s) \pmod{360}$$
3. **Candle Flicker:** Uses a pseudo-random number generator combined with scaling factors to create a cozy, organic light glow:
   $$\text{Intensity} = \text{Random}(0.6, 1.0), \quad \text{Color} = \text{Lerp}(\text{DeepOrange}, \text{WarmAmber}, \text{Random})$$
4. **Sunset Glow & Ocean Waves:** Utilizes vector arrays of warm/cool color palettes. It maps the current elapsed time as a fractional position index, then applies **linear color interpolation (`Color.lerp`)** between adjacent index frames to achieve a continuous, organic, slow-rolling color shift.

---

# 6. Building and Compiling Standalone Utilities

### Compiling `KB RGB Control.exe` from PowerShell:
The standalone GUI app is written in pure PowerShell 5.1 using a WPF (Windows Presentation Foundation) XML window layout, completely eliminating any external dependencies or DLL installers.

To compile the `kb-rgb-control.ps1` script into a lightweight standalone `.exe` file that has no visible console window and automatically prompts for administrative UAC privileges:

1. Install the compiler module:
   ```powershell
   Install-Module ps2exe -Scope CurrentUser
   ```
2. Run the compiler:
   ```powershell
   Import-Module ps2exe
   Invoke-PS2EXE `
       -InputFile  '.\kb_rgb_control_powershell\kb-rgb-control.ps1' `
       -OutputFile '.\kb_rgb_control_powershell\KB RGB Control.exe' `
       -noConsole `
       -requireAdmin `
       -iconFile   '.\kb_rgb_control_powershell\kb-rgb.ico' `
       -title       'KB RGB Control' `
       -description 'Native Backlight RGB Tuning Utility' `
       -version     '1.0.0.0'
   ```

---

## License

This software is released under the **MIT License**. It is completely open-source, free to use, modify, and distribute. Developed as a contribution to the gaming laptop community as a lightweight alternative to resource-heavy pre-installed background suites.
