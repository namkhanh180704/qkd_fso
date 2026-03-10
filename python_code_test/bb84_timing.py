#!/usr/bin/env python3
"""
bb84_timing.py — Table III: FPGA vs MATLAB Processing Time
═══════════════════════════════════════════════════════════

Phần FPGA: tính trực tiếp từ Verilog parameters (không cần board)
Phần MATLAB: nhập thủ công sau khi chạy MATLAB timing script

Chạy:
  python bb84_timing.py                          # FPGA only
  python bb84_timing.py --matlab 45,120,38,5,2   # Với MATLAB data (ms)
"""

import argparse, os, math
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

# ============================================================
# FPGA Parameters (from Verilog source)
# ============================================================
F_CLK       = 50_000_000     # 50 MHz
N_QUBITS    = 10_000         # Standard test size
N_WINDOW    = 256            # channel_monitor window
N_WINDOWS   = N_QUBITS // N_WINDOW  # ~39 windows

# Slot widths (clock cycles)
SLOT_FIXED  = 250_000        # 5ms (fixed mode default in paper)
SLOT_AGG    = 250_000        # 5ms (aggressive)
SLOT_MOD    = 500_000        # 10ms
SLOT_CON    = 2_500_000      # 50ms

def fpga_timing():
    """Compute per-module FPGA processing time."""
    cycle_ns = 1e9 / F_CLK  # 20ns per cycle

    modules = {}

    # BB84 Encode/Decode: alice.v + bob.v + error_estimation.v
    # Combinational: 1 cycle latch + 1 cycle compute = ~4 cycles/qubit
    cycles = 4 * N_QUBITS
    modules['BB84 Encode/Decode'] = cycles / F_CLK * 1000  # ms

    # OOK TX/RX: serializer = 4 cycles overhead per qubit
    # Physical slot time is separate (not computational)
    # Computational: bit packing, sync detection, edge debounce
    cycles = 16 * N_QUBITS  # 16 cycles overhead per qubit
    modules['OOK TX/RX'] = cycles / F_CLK * 1000  # ms
    # Note: physical time = 4 × slot_width × N ≈ 200s at 5ms slots
    # This is protocol-inherent, not computational

    # Gamma-Gamma Channel Emulator: ROM lookup + multiply + compare
    # 3 cycles per qubit (ROM read, multiply, impairment)
    cycles = 3 * N_QUBITS
    modules['G-G Channel Emulator'] = cycles / F_CLK * 1000  # ms

    # Channel Monitor: accumulate + window computation
    # 2 cycles per event + 10 cycles per window (QBER approx function)
    cycles = 2 * N_QUBITS + 10 * N_WINDOWS
    modules['Channel Monitor'] = cycles / F_CLK * 1000  # ms

    # Adaptive Controller: mode decision + hysteresis
    # 5 cycles per window (state machine)
    cycles = 5 * N_WINDOWS
    modules['Adaptive Controller'] = cycles / F_CLK * 1000  # ms

    return modules

def print_table(fpga, matlab=None):
    """Print Table III in terminal and LaTeX."""
    print(f"\n{'='*70}")
    print(f"  Table III: Processing Time (N = {N_QUBITS:,} qubits)")
    print(f"  FPGA: Cyclone II @ {F_CLK/1e6:.0f} MHz")
    if matlab:
        print(f"  MATLAB: (user-provided timings)")
    print(f"{'='*70}")

    header = f"  {'Module':25s} │ {'MATLAB (ms)':>12s} │ {'FPGA (ms)':>12s} │ {'Speedup':>8s}"
    print(header)
    print(f"  {'─'*25}─┼─{'─'*12}─┼─{'─'*12}─┼─{'─'*8}")

    total_fpga = 0
    total_matlab = 0
    modules_list = ['BB84 Encode/Decode', 'OOK TX/RX', 'G-G Channel Emulator',
                    'Channel Monitor', 'Adaptive Controller']

    for i, mod in enumerate(modules_list):
        f_time = fpga[mod]
        total_fpga += f_time

        if matlab and i < len(matlab):
            m_time = matlab[i]
            total_matlab += m_time
            speedup = m_time / f_time if f_time > 0.0001 else float('inf')
            print(f"  {mod:25s} │ {m_time:>12.1f} │ {f_time:>12.3f} │ {speedup:>7.0f}x")
        else:
            print(f"  {mod:25s} │ {'---':>12s} │ {f_time:>12.3f} │ {'---':>8s}")

    print(f"  {'─'*25}─┼─{'─'*12}─┼─{'─'*12}─┼─{'─'*8}")
    if matlab:
        speedup_total = total_matlab / total_fpga if total_fpga > 0 else 0
        print(f"  {'Total':25s} │ {total_matlab:>12.1f} │ {total_fpga:>12.3f} │ {speedup_total:>7.0f}x")
    else:
        print(f"  {'Total':25s} │ {'---':>12s} │ {total_fpga:>12.3f} │ {'---':>8s}")

    # KEY INSIGHT
    print(f"\n  ⚡ NOTE: FPGA modules run in PARALLEL")
    print(f"     Computational overhead of all modules: {total_fpga:.3f}ms")
    print(f"     Physical slot time (separate): 4 × {SLOT_FIXED/F_CLK*1000:.0f}ms × N = {4*SLOT_FIXED*N_QUBITS/F_CLK:.0f}s")
    print(f"     → Adaptive controller adds < {fpga['Adaptive Controller']:.3f}ms overhead")

    # LaTeX
    print(f"\n{'='*70}")
    print(f"  LaTeX Table III")
    print(f"{'='*70}")
    print(r"\begin{tabular}{l|r|r|r}")
    print(r"\hline")
    print(r"\textbf{Module} & \textbf{MATLAB} & \textbf{FPGA} & \textbf{Speedup} \\")
    print(r"                 & \textbf{(ms)}   & \textbf{(ms)} & \\")
    print(r"\hline")
    for i, mod in enumerate(modules_list):
        f_time = fpga[mod]
        if matlab and i < len(matlab):
            m_time = matlab[i]
            sp = m_time / f_time if f_time > 0.0001 else 0
            print(f"{mod:25s} & {m_time:.1f} & {f_time:.3f} & {sp:.0f}$\\times$ \\\\")
        else:
            print(f"{mod:25s} & --- & {f_time:.3f} & --- \\\\")
    print(r"\hline")
    if matlab:
        sp = total_matlab / total_fpga if total_fpga > 0 else 0
        print(f"{'\\textbf{Total}':25s} & {total_matlab:.1f} & {total_fpga:.3f} & \\textbf{{{sp:.0f}$\\times$}} \\\\")
    print(r"\hline")
    print(r"\end{tabular}")

    return total_fpga, total_matlab if matlab else 0

def plot_timing(fpga, matlab, output_dir='.'):
    """Fig 5: Per-module timing comparison (log scale)."""
    if not matlab:
        return

    modules = ['BB84\nEncode', 'OOK\nTX/RX', 'G-G\nChannel', 'Channel\nMonitor', 'Adaptive\nCtrl']
    fpga_times = [fpga[m] for m in ['BB84 Encode/Decode','OOK TX/RX',
                  'G-G Channel Emulator','Channel Monitor','Adaptive Controller']]

    fig, ax = plt.subplots(figsize=(10, 6))
    x = np.arange(len(modules))
    w = 0.35
    ax.bar(x - w/2, matlab, w, color='#ef4444', label='MATLAB', edgecolor='k', lw=0.5)
    ax.bar(x + w/2, fpga_times, w, color='#3b82f6', label='FPGA', edgecolor='k', lw=0.5)
    ax.set_yscale('log')
    ax.set_ylabel('Processing Time (ms)', fontsize=12)
    ax.set_xlabel('Module', fontsize=12)
    ax.set_title(f'Per-Module Processing Time: MATLAB vs FPGA (N={N_QUBITS:,})', fontsize=13)
    ax.set_xticks(x)
    ax.set_xticklabels(modules)
    ax.legend(fontsize=11)
    ax.grid(True, alpha=0.3, which='both', axis='y')

    # Speedup labels
    for i in range(len(modules)):
        if fpga_times[i] > 0 and matlab[i] > 0:
            sp = matlab[i] / fpga_times[i]
            ymax = max(matlab[i], fpga_times[i])
            ax.text(x[i], ymax * 1.5, f'{sp:.0f}×', ha='center',
                    fontsize=10, fontweight='bold', color='#059669')

    fig.tight_layout()
    path = os.path.join(output_dir, 'fig_timing_comparison.png')
    fig.savefig(path, dpi=200, bbox_inches='tight')
    plt.close(fig)
    print(f"\n  ✅ {path}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--matlab', type=str, default=None,
                    help='MATLAB timings as comma-separated ms: bb84,ook,gg,monitor,adapt')
    ap.add_argument('--output-dir', default='.')
    args = ap.parse_args()

    fpga = fpga_timing()

    matlab = None
    if args.matlab:
        matlab = [float(x) for x in args.matlab.split(',')]
        if len(matlab) != 5:
            print("ERROR: need exactly 5 MATLAB timings")
            return

    print_table(fpga, matlab)
    if matlab:
        plot_timing(fpga, matlab, args.output_dir)

    # Also print MATLAB timing script
    print(f"\n{'='*70}")
    print("  MATLAB Timing Script (copy and run in MATLAB)")
    print(f"{'='*70}")
    print("""
%% BB84_QKD_FPGA_vs_MATLAB.m — Timing comparison
N = 10000;  Nw = 256;

%% 1. BB84 Encode/Decode
tic;
for i = 1:N
    a = randi([0,1]); b = randi([0,1]);
    qubit = mod(a + b*2, 4);
    bp = randi([0,1]);
    if b == bp, decoded = a; else, decoded = randi([0,1]); end
end
t1 = toc*1000; fprintf('BB84 Encode/Decode: %.1f ms\\n', t1);

%% 2. OOK TX/RX (simulated framing)
tic;
for i = 1:N
    frame = [1, randi([0,1]), randi([0,1]), 0];
    received = frame;  % loopback
end
t2 = toc*1000; fprintf('OOK TX/RX: %.1f ms\\n', t2);

%% 3. Gamma-Gamma Channel
tic;
alpha = 4.198; beta = 2.269;
for i = 1:N
    x = gamrnd(alpha, 1/alpha);
    y = gamrnd(beta, 1/beta);
    I = x * y;
    fade = (I < 0.3);
end
t3 = toc*1000; fprintf('G-G Channel: %.1f ms\\n', t3);

%% 4. Channel Monitor
tic;
qber_acc = 0; snr_acc = 0;
for i = 1:N
    qber_acc = qber_acc + randi([0,1]);
    if mod(i, Nw) == 0
        qber_val = qber_acc / Nw;
        qber_acc = 0;
    end
end
t4 = toc*1000; fprintf('Channel Monitor: %.1f ms\\n', t4);

%% 5. Adaptive Controller
tic;
mode = 1;
for w = 1:(N/Nw)
    qber = rand()*20; snr = rand()*255;
    if qber >= 15, target = 3;
    elseif qber >= 8, target = 2;
    elseif qber < 4 && snr > 180, target = 0;
    else, target = 1; end
    mode = target;
end
t5 = toc*1000; fprintf('Adaptive Controller: %.1f ms\\n', t5);

fprintf('\\nTotal: %.1f ms\\n', t1+t2+t3+t4+t5);
fprintf('Run: python bb84_timing.py --matlab %.1f,%.1f,%.1f,%.1f,%.1f\\n',...
        t1,t2,t3,t4,t5);
""")

if __name__ == '__main__':
    main()
