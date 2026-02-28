# fabi386: Target Platform - MiSTer FPGA (DE10-Nano)

## DE10-Nano Hardware (Official Specs)

### FPGA
- **Device:** Intel/Altera Cyclone V SE 5CSEBA6U23I7
- **Logic Elements:** 110K LEs
- **ALMs:** 41,910 (~84K LUT-equivalent)
- **M10K BRAM:** 553 blocks (5,662 Kbit)
- **DSP 18x18:** 112 multipliers
- **Configuration:** EPCS64 serial config device, FPGA Configuration Mode Switch

### Hard Processor System (HPS)
- **CPU:** 800MHz Dual-core ARM Cortex-A9
- **RAM:** 1GB DDR3 SDRAM (32-bit bus, x2 devices)
- **Networking:** Gigabit Ethernet
- **Storage:** Micro SD card socket
- **USB:** USB OTG port
- **UART:** UART-to-USB controller

### Onboard I/O
- **Video:** HDMI TX controller (DVI 1.0 / HDCP v1.4)
- **JTAG:** USB-Blaster II (MAX II + USB PHY)
- **GPIO:** 2x 2x20 GPIO headers (active top + bottom)
- **Arduino:** Arduino Uno R3 compatible header (digital + analog)
- **ADC:** 2x5 ADC header with onboard ADC
- **LTC:** LTC 2x7 header (SPI master, I2C, GPIO)
- **Switches:** 4x user DIP switches
- **Buttons:** 2x FPGA pushbuttons + HPS user button
- **LEDs:** 8x FPGA LEDs + HPS user LED
- **Sensors:** G-Sensor (accelerometer)
- **Reset:** WARM_RST, HPS_RST
- **Power:** 5V DC power jack
- **Toolchain:** Intel Quartus Prime

### MiSTer Add-On SDRAM (Active on GPIO Headers)
- **Primary SDRAM:** 32MB module (active on top GPIO header)
- **Expansion SDRAM:** 128MB module (active on bottom GPIO header)
- **Total FPGA-side RAM:** 160MB SDRAM
- **Note:** The 1GB DDR3 is HPS-side only (ARM Linux); the FPGA fabric accesses the 32MB + 128MB SDRAM modules via the GPIO headers

## Resource Fit

| Resource            | Cyclone V Available   | fabi386 Requirement | Headroom |
|---------------------|-----------------------|---------------------|----------|
| Logic Elements      | 110K LEs              | ~63K LUT-eq        | ~47K     |
| ALMs (~2x LUT4)     | 41,910 (~84K LUT-eq) | ~63K LUTs           | ~21K     |
| M10K BRAM blocks    | 553 (5.5 Mbit)       | 170 (18Kb-eq)       | ~383     |
| DSP 18x18           | 112                   | 60                  | 52       |

The 110K LE count gives comfortable headroom for the fabi386 core plus the
Ultra-RE instrumentation suite (~10,450 LUTs). Even with MiSTer framework
overhead (video_mixer, OSD, HPS bridge), resource utilization stays well
under 80%.

## Memory Map Adaptation

The original design uses 256MB HyperRAM. On MiSTer with 128MB expansion:

| Function                | Original (HyperRAM) | MiSTer (SDRAM)              |
|-------------------------|----------------------|-----------------------------|
| Main system memory      | 256MB HyperRAM       | 32MB primary SDRAM          |
| Trace buffer / RE data  | Shared in HyperRAM   | 128MB expansion SDRAM       |
| L2 cache backing        | HyperRAM             | FPGA BRAM (on-chip)         |

The 128MB expansion module can be dedicated to the Ultra-RE trace buffer,
giving ~10M+ instruction traces for time-travel debugging. The 32MB primary
SDRAM serves as main system memory (more than enough for DOS/Win9x workloads).

The HPS-side 1GB DDR3 is available for the ARM Linux system running MiSTer's
menu/OSD, SD card filesystem access, and USB input management.

## Adaptation Points

### Must Change
- `f386_hyperbus_ctrl.sv` → Replace with MiSTer SDRAM controller interface
- Pin constraints → MiSTer DE10-Nano `.qsf` pinout
- Build scripts → Quartus synthesis flow

### Can Leverage from MiSTer Framework
- **Video output:** MiSTer's `video_mixer` and HDMI/VGA scan-doubler
- **SD card access:** HPS-side SD card via ARM Linux (for IDE DMA)
- **OSD/Menu:** MiSTer's standard OSD for configuration
- **UART debug:** MiSTer has accessible UART pins for the fabi386 console
- **USB input:** HPS-managed keyboard/mouse passthrough

### RTL Portable As-Is
- All `core/` modules (pipeline, ALU, FPU, branch prediction, OoO engine)
- All `soc/` modules (debug unit, guard unit, PASC, V86 monitor, BitBlt)
- Package and type definitions (`f386_pkg.sv`)
- Microcode ROM, dispatch, register rename, ROB, issue queue
