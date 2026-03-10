# FPGA-Based Adaptive BB84 QKD over Gamma–Gamma FSO Channels

Real-time optimization of photon intensity and basis bias for Quantum Key Distribution over turbulent free-space optical links, implemented on Altera Cyclone II FPGA.

> **Paper:** *FPGA-Based Real-Time Optimization of Photon Intensity and Basis Bias for Adaptive Quantum Key Distribution over Gamma–Gamma FSO Channels*
>
> **Authors:** Nam Khanh Duong, Huy Dung Han, Xuan Quang Phuong, Duyen Trung Ha*
>
> **Affiliation:** School of Electrical and Electronic Engineering, Hanoi University of Science and Technology (HUST)
>
> **Funding:** HUST project T2025-PC-068

---

## Overview

This project implements a complete BB84 QKD system on FPGA with a closed-loop adaptive controller that dynamically adjusts transmission parameters in response to atmospheric turbulence. The system includes an on-chip Gamma–Gamma channel emulator for real-time testing without optical hardware.

### Key Results

| Metric | Fixed | Adaptive | Improvement |
|--------|-------|----------|-------------|
| QBER at Level 4 (Strong) | 11.7% ❌ | 8.7% ✅ | −3.0% |
| SKR at Level 3 (Moderate) | 0.106 b/pulse | 0.216 b/pulse | **2.04×** |
| Sifting Efficiency | 50% | 68% | +36% |
| Secure Operating Range | Levels 0–3 | Levels 0–4 | **+1 level** |

The adaptive controller extends the secure operating range by one full turbulence level — at Level 4, the fixed system exceeds the BB84 security threshold (11%) and cannot generate secure keys, while the adaptive system maintains QBER below 11% with positive key rate.

### Architecture

```
TRNG ×3 → Alice → OOK TX → PWM → Gamma-Gamma Emulator → OOK RX → Bob
                                                                    ↓
   ┌─── basis_prob ──── slot_width ──── power_level ←── Adaptive ← Error Est.
   ↓         ↓               ↓              ↓          Controller     ↓
 Alice    OOK TX/RX       OOK TX/RX        PWM             ↑     Channel
                                                        Monitor → UART → PC
```

## Hardware Platform

- **FPGA:** Altera Cyclone II EP2C20F484C7
- **Board:** Terasic DE1 Development Board
- **Clock:** 50 MHz
- **Interface:** RS-232 (115200 baud) for data logging
- **Resource Usage:** 4,600 / 18,752 LEs (24.5%), 1 multiplier, Fmax = 63.74 MHz

## Project Structure

```
├── verilog/                    # RTL source (14 modules, ~3,100 lines)
│   ├── top_module.v            # Top-level with BB84 FSM
│   ├── alice.v                 # BB84 encoder
│   ├── bob.v                   # BB84 decoder
│   ├── trng.v                  # Ring oscillator TRNG (4 ROs + Von Neumann)
│   ├── trng_random.v           # TRNG wrapper (drop-in for LFSR)
│   ├── ook_tx_serializer.v     # OOK modulator (4-slot framing)
│   ├── ook_rx_deserializer.v   # OOK demodulator (edge-triggered sync)
│   ├── pwm_and_basis.v         # PWM power control + biased basis selector
│   ├── gamma_gamma_final.v     # Gamma-Gamma channel emulator (ROM-based)
│   ├── error_estimation.v      # Sifting and error detection
│   ├── channel_monitor.v       # Sliding-window QBER/SNR estimator
│   ├── adaptive_controller.v   # 4-mode FSM with asymmetric hysteresis
│   ├── uart_tx.v               # UART transmitter
│   ├── uart_rx.v               # UART receiver
│   └── uart_reporter.v         # Per-qubit and per-window packet formatter
│
├── constraints/
│   └── bb84_phase2.sdc         # Timing constraints (false paths for TRNG ROs)
│
├── python/                     # Measurement and visualization scripts
│   ├── bb84_fpga_qber_snr_5_level.py      # QBER vs SNR curves (FPGA or simulation)
│   ├── bb84_table2.py          # Aggregate Table II data collection
│   ├── bb84_timing.py          # FPGA vs MATLAB timing comparison
│   └── regen_paper_figs.py     # Generate all paper figures
│
├── docs/
│   └── paper.pdf               # Conference paper
│
└── README.md
```

## Adaptive Controller

The controller partitions channel conditions into four operating modes:

| Mode | QBER | SNR | Power | Basis (p_z) | Slot Width | Strategy |
|------|------|-----|-------|-------------|------------|----------|
| **Aggressive** | < 4% | > 180 | 6/15 | 50% | 5 ms | Max throughput |
| **Moderate** | < 8% | > 100 | 10/15 | 60% | 10 ms | Balanced |
| **Conservative** | < 15% | > 40 | 15/15 | 80% | 50 ms | Max reliability |
| **Pause** | ≥ 15% | ≤ 40 | — | — | — | Suspend TX |

**Hysteresis policy:** Downgrade is immediate (security-first). Upgrade requires 3 consecutive favorable windows to filter transient improvements.

## Gamma–Gamma Channel Emulator

Hardware implementation of the two-scale multiplicative fading model `I = X · Y`:

- **ROM-based inverse CDF** lookup: 256×8-bit per parameter per level
- **4 LFSRs** (32/32/16/20-bit) for pseudo-random addresses
- **8×8 embedded multiplier** for irradiance computation
- **5 turbulence levels:** Weak (σ²_R=0.2) to Severe (σ²_R=8.0)
- **Deep fade model:** irradiance < 38 → random output (50% QBER)

## Quick Start

### Run on FPGA

1. Open project in Quartus II 13.0
2. Compile and program the DE1 board
3. Set DIP switches:
   - `SW[9]` = 1 (PC input mode)
   - `SW[4]` = 1 (turbulence ON)
   - `SW[7:5]` = turbulence level (001–101)
   - `SW[1]` = 0 (fixed) or 1 (adaptive)
   - `SW[0]` = 0 (auto mode)
4. Connect RS-232 and run:

```bash
python python/bb84_qber_curve.py --port COM28 --level 3 --batch 5000
```

### Run Simulation (no hardware needed)

```bash
# QBER vs SNR curves for all turbulence levels
python python/bb84_qber_curve.py --simulate --level all --batch 5000

# Aggregate performance table (Table II)
python python/bb84_table2.py --simulate --batch 5000

# Generate all paper figures
python python/regen_paper_figs.py
```

### Requirements

```bash
pip install numpy matplotlib scipy pyserial
```

## Switch Configuration

| Switch | Function | Values |
|--------|----------|--------|
| `SW[9]` | PC input mode | 0 = autonomous, 1 = PC control |
| `SW[7:5]` | Turbulence level | 000=OFF, 001=Weak, ..., 101=Severe |
| `SW[4]` | Turbulence enable | 0 = bypass, 1 = enabled |
| `SW[1]` | Adaptive control | 0 = fixed params, 1 = adaptive |
| `SW[0]` | Auto/manual | 0 = auto run, 1 = manual (KEY[1]) |
| `KEY[3]` | Reset | Press to reset all modules |
| `KEY[0]` | Eavesdropper | Hold to simulate intercept-resend |

## LED Indicators

| LED | Function |
|-----|----------|
| `LEDR[1:0]` | TX qubit (basis, data) |
| `LEDR[3:2]` | RX qubit |
| `LEDR[4]` | TX active |
| `LEDR[5]` | RX active |
| `LEDR[6]` | Signal detect |
| `LEDR[7]` | Basis match |
| `LEDG[1:0]` | Adaptive mode (00=AGG, 01=MOD, 10=CON, 11=PAU) |
| `LEDG[6]` | Adaptive enabled |

## UART Protocol

**PC → FPGA** (1 byte):
- Bit[7] = 1: Qubit command — Bit[2]=alice_data, Bit[1]=alice_basis, Bit[0]=bob_basis
- `0x01`: Reset statistics
- `0x02`: Request status

**FPGA → PC** (per-qubit response):
```
@<a_data>,<a_basis>,<b_basis>,<bob_bit>,<basis_match>,<error>,<irradiance>,<total_hex>,<sifted_hex>,<errors_hex>*\r\n
```

## Timing Constraints

The TRNG uses intentional ring oscillator combinational loops for entropy generation. The SDC file (`bb84_phase2.sdc`) declares false paths for these loops:

```tcl
set_false_path -from [get_keepers {*trng_core*ro*_chain*}]
```

After applying constraints: Setup Slack = +4.312 ns, Fmax = 63.74 MHz.

## Citation

```bibtex
@inproceedings{duong2026fpga_adaptive_qkd,
  title     = {FPGA-Based Real-Time Optimization of Photon Intensity and 
               Basis Bias for Adaptive Quantum Key Distribution over 
               Gamma--Gamma FSO Channels},
  author    = {Duong, Nam Khanh and Han, Huy Dung and Phuong, Xuan Quang 
               and Ha, Duyen Trung},
  booktitle = {Proc. IEEE International Conference},
  year      = {2026},
  note      = {Funded by HUST project T2025-PC-068}
}
```

## License

This project is developed at Hanoi University of Science and Technology (HUST) under project T2025-PC-068. Please contact the authors for licensing information.

## Acknowledgments

The authors thank the School of Electrical and Electronic Engineering, HUST, for providing laboratory facilities and FPGA development boards.
