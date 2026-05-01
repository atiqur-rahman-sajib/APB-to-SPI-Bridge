# APB to SPI Bridge - SystemVerilog

## Project Overview

An APB (Advanced Peripheral Bus) to SPI (Serial Peripheral Interface) Bridge implemented in SystemVerilog. The design allows a CPU-side APB master to initiate SPI transfers, transmit data over MOSI, and capture responses from MISO — fully verified through an integration testbench with a behavioural SPI slave.

## Specifications

* **APB Clock Frequency** : 100 MHz
* **SPI Mode** : Mode 0 (CPOL=0, CPHA=0)
* **SPI Clock** : `pclk / (2 × CLK_DIV)` → 12.5 MHz at default `CLK_DIV=4`
* **Data Bits** : 8 (MSB first)
* **Chip Select** : Active-low (`cs_n`), asserted for full transfer duration
* **Interface** : APB3 slave + SPI master

## Register Map

| Address | Name     | Access | Description                                      |
|---------|----------|--------|--------------------------------------------------|
| `0x00`  | CTRL     | W      | `[0]` = start — write 1 to kick off SPI transfer (auto-clears) |
| `0x04`  | STATUS   | R      | `[0]` = busy — reads 1 while transfer is in progress |
| `0x08`  | TX_DATA  | R/W    | Byte to transmit on MOSI                         |
| `0x0C`  | RX_DATA  | R      | Byte captured from MISO during last transfer     |

## Files

* `design.sv` : APB to SPI Bridge module (`apb_spi_bridge`)
* `testbench.sv` : Integration testbench (`tb`) with APB master tasks and behavioural SPI slave

## How It Works

The bridge contains a 3-state SPI master FSM:

* **IDLE** : APB registers accessible; waits for `CTRL.start` pulse
* **RUN** : Asserts `cs_n`, generates SCLK, shifts TX data out on MOSI, and captures MISO into RX shift register (16 half-bit ticks for 8 bits)
* **DONE** : Latches received byte into `RX_DATA`, de-asserts `cs_n`, returns to IDLE

The half-bit clock tick is derived from a configurable divider (`CLK_DIV`). On each tick, even counts produce a rising SCLK edge (MISO sampled), odd counts produce a falling edge (MOSI updated).

## Test Cases

| Test | CPU → MOSI | Slave → MISO | Result |
|------|-----------|--------------|--------|
| T1   | `0xA5`    | `0x3C`       | PASS   |
| T2   | `0x00`    | `0xFF`       | PASS   |
| T3   | `0xFF`    | `0x00`       | PASS   |
| T4   | `0x55`    | `0xAA`       | PASS   |
| T5   | `0x12`    | `0x34`       | PASS   |
| T6   | `0xDE`    | `0xAD`       | PASS   |
| T7   | `0xBE`    | `0xEF`       | PASS   |

Each test performs a full round-trip: CPU writes `TX_DATA`, asserts `CTRL.start`, polls `STATUS.busy`, then verifies both what the slave received (MOSI integrity) and what the CPU read back from `RX_DATA` (MISO integrity).

## Simulation Output

```
=== APB to SPI Bridge integration tests ===

[T1] CPU sent 0xa5, slave got 0xa5 | slave sent 0x3c, CPU got 0x3c  >> PASS
[T2] CPU sent 0x00, slave got 0x00 | slave sent 0xff, CPU got 0xff  >> PASS
[T3] CPU sent 0xff, slave got 0xff | slave sent 0x00, CPU got 0x00  >> PASS
[T4] CPU sent 0x55, slave got 0x55 | slave sent 0xaa, CPU got 0xaa  >> PASS
[T5] CPU sent 0x12, slave got 0x12 | slave sent 0x34, CPU got 0x34  >> PASS
[T6] CPU sent 0xde, slave got 0xde | slave sent 0xad, CPU got 0xad  >> PASS
[T7] CPU sent 0xbe, slave got 0xbe | slave sent 0xef, CPU got 0xef  >> PASS

==========================================================
        ***  ALL APB-SPI BRIDGE TESTS PASSED  ***
==========================================================
```

## How to Simulate

Simulated using **QuestaSim 2025.2** with SystemVerilog support.

```bash
qrun -batch -access=rw+/. -timescale 1ns/1ns -mfcu design.sv testbench.sv \
     -do "run -all; exit"
```

Waveform output is written to `dump.vcd` and can be viewed in EPWave or GTKWave.

## Author

Atiqur Rahman Sajib
