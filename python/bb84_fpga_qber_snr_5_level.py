#!/usr/bin/env python3
"""
bb84_qber_curve.py — Đo QBER vs SNR trên FPGA thật (hoặc simulate)
════════════════════════════════════════════════════════════════════

Cách hoạt động:
  1. Thu thập N qubits (≥3000) tại 1 turbulence level
  2. Mỗi qubit nhận về: irradiance, basis_match, data_error, lost/ok
  3. Dùng sliding window (W=64 qubits) tính local QBER và local SNR
  4. Scatter plot + smooth fit → đường cong QBER vs SNR
  5. Chạy 2 lượt: Fixed (SW[1]=0) vs Adaptive (SW[1]=1)
  6. Vẽ 2 đường trên cùng 1 plot cho mỗi turbulence level

Chạy FPGA thật:
  python bb84_qber_curve.py --port COM28 --level 3 --batch 5000

Chạy simulation:
  python bb84_qber_curve.py --simulate --level 3 --batch 5000

Chạy tất cả levels:
  python bb84_qber_curve.py --simulate --level all --batch 5000
"""

import sys, time, random, argparse, os
import numpy as np

HAS_SERIAL = False
try:
    import serial; HAS_SERIAL = True
except ImportError: pass

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

# ============================================================
# TURBULENCE PARAMETERS (match FPGA gamma_gamma_final.v)
# ============================================================
TURB = {
    1: {'name':'WEAK',     'sigma_r2':0.2, 'alpha':11.651, 'beta':10.122, 'sw':'001'},
    2: {'name':'MILD',     'sigma_r2':0.5, 'alpha':5.978,  'beta':4.398,  'sw':'010'},
    3: {'name':'MODERATE', 'sigma_r2':1.2, 'alpha':4.198,  'beta':2.269,  'sw':'011'},
    4: {'name':'STRONG',   'sigma_r2':3.0, 'alpha':4.120,  'beta':1.435,  'sw':'100'},
    5: {'name':'SEVERE',   'sigma_r2':8.0, 'alpha':5.272,  'beta':1.134,  'sw':'101'},
}

# Match FPGA exactly
FADE_THRESH = 38          # gamma_gamma_final.v: deep_fade_thresh = 8'd38
IRRAD_MEAN  = 128         # 128 = I/I0 = 1.0
FAST_TIMEOUT = 0.05       # 50ms UART timeout

# Adaptive controller thresholds (match adaptive_controller.v)
QBER_GOOD = 4.0    # % → AGGRESSIVE
QBER_WARN = 8.0    # % → MODERATE→CONSERVATIVE
QBER_CRIT = 15.0   # % → PAUSE


# ============================================================
# FPGA CONNECTION — thu per-qubit data thật
# ============================================================
class FPGAConn:
    """Giao tiếp FPGA qua UART, thu per-qubit data."""

    def __init__(self, port, baud=115200):
        if not HAS_SERIAL:
            raise RuntimeError("Cần cài pyserial: pip install pyserial")
        self.ser = serial.Serial(port, baud, timeout=FAST_TIMEOUT)
        time.sleep(0.5)
        self.ser.reset_input_buffer()

    def echo_test(self):
        self.ser.reset_input_buffer()
        self.ser.write(bytes([0x80 | (1 << 2)]))
        time.sleep(0.1)
        line = self.ser.readline().decode('ascii', errors='ignore')
        return line.startswith('@')

    def reset_stats(self):
        self.ser.write(bytes([0x01]))
        time.sleep(0.05)
        self.ser.reset_input_buffer()

    def collect(self, n, basis_pz=0.5, seed=42):
        """
        Thu n qubits. Trả về list per-qubit records.

        basis_pz: xác suất chọn Z-basis (0.5=balanced, 0.8=biased)
                  Áp dụng trên Python side vì PC mode override FPGA basis.

        Mỗi record: {
            'irradiance': 0-255,      # kênh tốt=128, fade<38
            'basis_match': 0/1,
            'data_error': 0/1,
            'lost': True/False,       # True = timeout (deep fade)
            'a_data','a_basis','b_basis','bob_bit': int
        }
        """
        rng = np.random.RandomState(seed)
        self.reset_stats()
        records = []
        t0 = time.perf_counter()

        for i in range(n):
            # Tạo qubit với basis bias
            ad = rng.randint(0, 2)
            ab = 0 if rng.random() < basis_pz else 1  # 0=Z, 1=X
            bb = 0 if rng.random() < basis_pz else 1

            # Gửi lên FPGA
            cmd = 0x80 | (ad << 2) | (ab << 1) | bb
            self.ser.write(bytes([cmd]))

            # Đọc kết quả
            line = self.ser.readline().decode('ascii', errors='ignore')

            if line.startswith('@') and '*' in line:
                r = self._parse(line)
                if r:
                    r['lost'] = False
                    r['_sent_ab'] = ab
                    r['_sent_bb'] = bb
                    records.append(r)
                else:
                    records.append({
                        'irradiance': 0, 'basis_match': 0, 'data_error': 0,
                        'lost': True, 'a_data': ad, 'a_basis': ab,
                        'b_basis': bb, 'bob_bit': -1,
                    })
            else:
                # Timeout = deep fade
                records.append({
                    'irradiance': 0, 'basis_match': 0, 'data_error': 0,
                    'lost': True, 'a_data': ad, 'a_basis': ab,
                    'b_basis': bb, 'bob_bit': -1,
                })

            if (i + 1) % 200 == 0:
                dt = time.perf_counter() - t0
                n_lost = sum(1 for r in records if r['lost'])
                print(f"\r    [{i+1}/{n}] {(i+1)/dt:.0f} q/s | "
                      f"OK={len(records)-n_lost} lost={n_lost}", end='', flush=True)

        dt = time.perf_counter() - t0
        n_lost = sum(1 for r in records if r['lost'])
        print(f"\r    Xong: {len(records)-n_lost} OK + {n_lost} lost = {n} | "
              f"{n/dt:.0f} q/s | {dt:.1f}s" + " " * 20)
        return records

    def _parse(self, line):
        try:
            p = line.strip()[1:line.strip().index('*')].split(',')
            if len(p) < 10:
                return None
            return {
                'a_data': int(p[0]), 'a_basis': int(p[1]), 'b_basis': int(p[2]),
                'bob_bit': int(p[3]), 'basis_match': int(p[4]),
                'data_error': int(p[5]), 'irradiance': int(p[6]),
            }
        except Exception:
            return None

    def close(self):
        self.ser.close()


# ============================================================
# SIMULATION CONNECTION — mô phỏng chính xác hành vi FPGA
# ============================================================
class SimConn:
    """
    Mô phỏng chính xác FPGA loopback:
    - Irradiance = X*Y/128, X~Gamma(α), Y~Gamma(β)
    - Deep fade: irrad < 38 → lost (timeout)
    - Ngoài fade: truyền hoàn hảo (scint=0, flip=0 trên FPGA)
    """

    def __init__(self, alpha, beta):
        self.alpha = alpha
        self.beta = beta

    def echo_test(self):
        return True

    def reset_stats(self):
        pass

    def collect(self, n, basis_pz=0.5, seed=42):
        rng = np.random.RandomState(seed)
        records = []

        for i in range(n):
            # Gamma-Gamma irradiance (match FPGA ROM-based sampling)
            x = rng.gamma(self.alpha, 1.0 / self.alpha)
            y = rng.gamma(self.beta, 1.0 / self.beta)
            irr_float = x * y
            irr_hw = min(int(irr_float * IRRAD_MEAN), 255)

            # Basis with bias
            ad = rng.randint(0, 2)
            ab = 0 if rng.random() < basis_pz else 1
            bb = 0 if rng.random() < basis_pz else 1

            # Deep fade check (match FPGA: in_deep_fade = irr < 38)
            if irr_hw < FADE_THRESH:
                records.append({
                    'irradiance': irr_hw, 'basis_match': 0,
                    'data_error': 0, 'lost': True,
                    'a_data': ad, 'a_basis': ab, 'b_basis': bb, 'bob_bit': -1,
                })
                continue

            # BB84: matching basis → correct bit, else random
            # (match FPGA: outside fade, signal passes perfectly)
            if ab == bb:
                bob_bit = ad      # Perfect transmission
                basis_match = 1
                data_error = 0    # No errors outside fade
            else:
                bob_bit = rng.randint(0, 2)
                basis_match = 0
                data_error = 0

            records.append({
                'irradiance': irr_hw, 'basis_match': basis_match,
                'data_error': data_error, 'lost': False,
                'a_data': ad, 'a_basis': ab, 'b_basis': bb, 'bob_bit': bob_bit,
            })

        n_lost = sum(1 for r in records if r['lost'])
        print(f"    Xong: {n - n_lost} OK + {n_lost} lost = {n} (sim)")
        return records

    def close(self):
        pass


# ============================================================
# SLIDING WINDOW ANALYSIS
# ============================================================
def sliding_window_analysis(records, window_size=64):
    """
    Dùng sliding window để tính local QBER và local SNR.

    Trả về arrays: (snr_proxy, qber_pct)
    - snr_proxy: tỉ lệ qubits nhận được trong window (0-1) → map to 0-255
    - qber_pct: QBER (%) tính trên window đó

    Cách tính QBER bao gồm lost qubits:
      - Lost qubit → basis_match~50%, error~50% → QBER~50% trên phần lost
      - QBER_window = (errors_ok + 0.5 * lost * 0.5) / (sifted_ok + lost * 0.5)
    """
    n = len(records)
    if n < window_size:
        return np.array([]), np.array([])

    snr_list = []
    qber_list = []
    irrad_list = []

    for start in range(0, n - window_size + 1, window_size // 4):
        window = records[start:start + window_size]

        n_lost = sum(1 for r in window if r['lost'])
        n_ok = len(window) - n_lost

        # SNR proxy = fraction of qubits received
        recv_frac = n_ok / len(window)
        snr_proxy = recv_frac * 255  # Scale to 0-255

        # Mean irradiance of received qubits
        irr_vals = [r['irradiance'] for r in window if not r['lost']]
        mean_irr = np.mean(irr_vals) if irr_vals else 0

        # QBER: count sifted + errors from OK qubits
        sifted_ok = sum(1 for r in window if not r['lost'] and r['basis_match'])
        errors_ok = sum(1 for r in window if not r['lost'] and r['basis_match']
                        and r['data_error'])

        # Lost qubits contribute: ~50% would have matched basis, ~50% of those error
        sifted_lost_est = n_lost * 0.5
        errors_lost_est = sifted_lost_est * 0.5

        total_sifted = sifted_ok + sifted_lost_est
        total_errors = errors_ok + errors_lost_est

        if total_sifted > 0:
            qber = 100.0 * total_errors / total_sifted
        else:
            qber = 50.0

        snr_list.append(snr_proxy)
        qber_list.append(qber)
        irrad_list.append(mean_irr)

    return np.array(snr_list), np.array(qber_list), np.array(irrad_list)


# ============================================================
# SMOOTH CURVE FROM SCATTER
# ============================================================
def smooth_curve(x, y, n_bins=30, x_range=None):
    """
    Bin scatter data and compute smoothed curve.
    Returns (x_smooth, y_smooth) for plotting.
    """
    if len(x) == 0:
        return np.array([]), np.array([])

    if x_range is None:
        x_range = (x.min(), x.max())

    bin_edges = np.linspace(x_range[0], x_range[1], n_bins + 1)
    bin_centers = (bin_edges[:-1] + bin_edges[1:]) / 2
    bin_means = np.full(n_bins, np.nan)

    for i in range(n_bins):
        mask = (x >= bin_edges[i]) & (x < bin_edges[i + 1])
        if mask.sum() >= 2:
            bin_means[i] = np.mean(y[mask])

    # Remove NaN bins
    valid = ~np.isnan(bin_means)
    if valid.sum() < 3:
        return bin_centers[valid], bin_means[valid]

    # Interpolate gaps
    from scipy.interpolate import interp1d
    try:
        f = interp1d(bin_centers[valid], bin_means[valid], kind='cubic',
                      fill_value='extrapolate')
        x_smooth = np.linspace(bin_centers[valid].min(), bin_centers[valid].max(), 200)
        y_smooth = np.clip(f(x_smooth), 0, 50)

        # Additional Gaussian smooth
        from scipy.ndimage import gaussian_filter1d
        y_smooth = gaussian_filter1d(y_smooth, sigma=3)
        return x_smooth, y_smooth
    except Exception:
        return bin_centers[valid], bin_means[valid]


# ============================================================
# PLOTTING — 1 turbulence level, 2 curves
# ============================================================
def plot_level(level, snr_f, qber_f, irrad_f, snr_a, qber_a, irrad_a,
               source='FPGA', output_dir='.'):
    """Vẽ QBER vs SNR cho 1 turbulence level: Fixed (đỏ) vs Adaptive (cyan)."""
    p = TURB[level]

    fig, ax = plt.subplots(figsize=(10, 7))
    fig.patch.set_facecolor('#080810')
    ax.set_facecolor('#080810')
    ax.grid(True, which='major', color='#252535', linewidth=0.7)
    ax.grid(True, which='minor', color='#151520', linewidth=0.3)
    ax.minorticks_on()

    C_FIXED = '#FF3333'
    C_ADAPT = '#00DDFF'
    C_LIMIT = '#FFB000'

    # --- Scatter: raw window data ---
    ax.scatter(snr_f, qber_f, s=12, c=C_FIXED, alpha=0.15, zorder=3,
               edgecolors='none', label='_nolegend_')
    ax.scatter(snr_a, qber_a, s=12, c=C_ADAPT, alpha=0.15, zorder=3,
               edgecolors='none', label='_nolegend_')

    # --- Smooth curves ---
    x_range = (min(snr_f.min(), snr_a.min()) - 5,
               max(snr_f.max(), snr_a.max()) + 5)

    xs_f, ys_f = smooth_curve(snr_f, qber_f, n_bins=25, x_range=x_range)
    xs_a, ys_a = smooth_curve(snr_a, qber_a, n_bins=25, x_range=x_range)

    if len(xs_f) > 0:
        ax.plot(xs_f, ys_f, '-', color=C_FIXED, lw=3.0, label='Fixed Parameters', zorder=5)
        ax.plot(xs_f, ys_f, '-', color=C_FIXED, lw=7, alpha=0.15, zorder=4)
    if len(xs_a) > 0:
        ax.plot(xs_a, ys_a, '-', color=C_ADAPT, lw=3.0, label='Adaptive Control', zorder=5)
        ax.plot(xs_a, ys_a, '-', color=C_ADAPT, lw=7, alpha=0.15, zorder=4)

    # BB84 security limit
    ax.axhline(11, color=C_LIMIT, ls='--', lw=2.0, alpha=0.9,
               label='BB84 Limit (11%)', zorder=6)

    # Secure region
    ax.axhspan(0, 11, color='#002200', alpha=0.15, zorder=1)

    # Summary stats
    n_f = len(snr_f)
    n_a = len(snr_a)
    avg_qber_f = np.mean(qber_f) if len(qber_f) > 0 else 0
    avg_qber_a = np.mean(qber_a) if len(qber_a) > 0 else 0

    stats_text = (
        f'Fixed:    QBER = {avg_qber_f:.2f}%  (avg over {n_f} windows)\n'
        f'Adaptive: QBER = {avg_qber_a:.2f}%  (avg over {n_a} windows)\n'
        f'Δ = {avg_qber_f - avg_qber_a:+.2f}%'
    )
    ax.text(0.03, 0.03, stats_text, transform=ax.transAxes, fontsize=9,
            color='#AAAAAA', fontfamily='monospace', va='bottom',
            bbox=dict(boxstyle='round,pad=0.5', facecolor='#15151f',
                      edgecolor='#444444', alpha=0.9))

    # Axis labels
    ax.set_xlabel('SNR Proxy (received qubits / total in window × 255)',
                  fontsize=12, color='white', labelpad=8)
    ax.set_ylabel('QBER (%)', fontsize=12, color='white', labelpad=8)
    ax.set_title(
        f'QBER vs SNR — Level {level} ({p["name"]})\n'
        f'σ²_R = {p["sigma_r2"]},  α = {p["alpha"]:.2f},  β = {p["beta"]:.2f}'
        f'  [{source}]',
        fontsize=13, color='white', fontweight='bold', pad=12)

    ax.set_ylim(-0.5, max(35, max(qber_f.max(), qber_a.max()) * 1.2))
    ax.set_xlim(x_range)
    ax.tick_params(colors='white', which='both')
    for spine in ax.spines.values():
        spine.set_color('#444444')

    legend = ax.legend(loc='upper right', fontsize=11, framealpha=0.8,
                       edgecolor='#555555', facecolor='#15151f')
    for t in legend.get_texts():
        t.set_color('white')

    fig.tight_layout()
    outpath = os.path.join(output_dir, f'qber_snr_level{level}_{source.lower()}.png')
    fig.savefig(outpath, dpi=200, bbox_inches='tight', facecolor=fig.get_facecolor())
    plt.close(fig)
    print(f"  ✅ {outpath}")
    return outpath


# ============================================================
# MAIN
# ============================================================
def main():
    ap = argparse.ArgumentParser(
        description='BB84 QBER vs SNR curves — FPGA hoặc simulation',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ví dụ:
  # Simulation tất cả levels:
  python bb84_qber_curve.py --simulate --level all --batch 5000

  # FPGA thật, level 3:
  python bb84_qber_curve.py --port COM28 --level 3 --batch 5000

  # FPGA thật, tất cả levels:
  python bb84_qber_curve.py --port COM28 --level all --batch 5000
""")
    ap.add_argument('--port', help='COM port cho FPGA (vd: COM28)')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--simulate', action='store_true', help='Dùng simulation')
    ap.add_argument('--level', default='3',
                    help='Turbulence level: 1-5 hoặc "all"')
    ap.add_argument('--batch', type=int, default=5000,
                    help='Số qubits mỗi lượt (≥3000 cho smooth)')
    ap.add_argument('--window', type=int, default=64,
                    help='Sliding window size')
    ap.add_argument('--seed', type=int, default=42)
    ap.add_argument('--output-dir', default='.')
    args = ap.parse_args()

    if args.level == 'all':
        levels = [1, 2, 3, 4, 5]
    else:
        levels = [int(x) for x in args.level.split(',')]

    os.makedirs(args.output_dir, exist_ok=True)
    source = 'FPGA' if args.port else 'Sim'

    print(f"\n{'█' * 60}")
    print(f"  BB84 QBER vs SNR — {source}")
    print(f"  Levels: {levels}")
    print(f"  Batch: {args.batch} qubits × 2 (Fixed/Adaptive)")
    print(f"  Window: {args.window} qubits")
    print(f"{'█' * 60}")

    for lv in levels:
        p = TURB[lv]
        print(f"\n{'━' * 55}")
        print(f"  LEVEL {lv}: {p['name']} (σ²_R = {p['sigma_r2']})")
        print(f"  α = {p['alpha']:.3f}, β = {p['beta']:.3f}")
        print(f"{'━' * 55}")

        all_snr = {}
        all_qber = {}
        all_irrad = {}

        for adaptive_on in [False, True]:
            label = "Adaptive ON" if adaptive_on else "Adaptive OFF"
            basis_pz = 0.5  # Fixed: balanced

            if adaptive_on:
                # Adaptive: dùng basis bias phù hợp với turbulence level
                # Level 1-2: controller likely stays AGG/MOD → pz=0.5-0.6
                # Level 3: controller goes CON → pz=0.8
                # Level 4-5: controller goes CON/PAU → pz=0.8
                if lv <= 1:
                    basis_pz = 0.55
                elif lv == 2:
                    basis_pz = 0.60
                else:
                    basis_pz = 0.80

            seed = args.seed + lv * 100 + (1 if adaptive_on else 0)

            print(f"\n  [{label}] basis_pz={basis_pz:.2f}, seed={seed}")

            if args.port:
                # FPGA thật
                sw1 = 1 if adaptive_on else 0
                print(f"  ► Đặt switch: SW[9]=1 SW[4]=1 SW[7:5]={p['sw']} "
                      f"SW[1]={sw1} SW[0]=0")
                print(f"  ► Nhấn KEY[3] (reset)")
                input(f"  ► Nhấn ENTER khi sẵn sàng...")

                conn = FPGAConn(args.port, args.baud)
                if not conn.echo_test():
                    print("  ✗ Không phản hồi! Nhấn KEY[3] rồi thử lại")
                    input("  ENTER...")
                    if not conn.echo_test():
                        print("  ✗ Bỏ qua")
                        conn.close()
                        continue
                records = conn.collect(args.batch, basis_pz=basis_pz, seed=seed)
                conn.close()
            else:
                # Simulation
                conn = SimConn(p['alpha'], p['beta'])
                records = conn.collect(args.batch, basis_pz=basis_pz, seed=seed)
                conn.close()

            # Sliding window analysis
            snr, qber, irrad = sliding_window_analysis(records, args.window)

            n_lost = sum(1 for r in records if r['lost'])
            n_ok = len(records) - n_lost
            print(f"    OK={n_ok} Lost={n_lost} ({100*n_lost/len(records):.1f}% fade)")
            print(f"    Windows: {len(snr)} | SNR range: {snr.min():.0f}–{snr.max():.0f}")
            print(f"    QBER range: {qber.min():.2f}%–{qber.max():.1f}%")
            print(f"    Mean QBER: {np.mean(qber):.2f}%")

            key = 'adapt' if adaptive_on else 'fixed'
            all_snr[key] = snr
            all_qber[key] = qber
            all_irrad[key] = irrad

        # Vẽ plot cho level này
        if 'fixed' in all_snr and 'adapt' in all_snr:
            plot_level(lv,
                       all_snr['fixed'], all_qber['fixed'], all_irrad['fixed'],
                       all_snr['adapt'], all_qber['adapt'], all_irrad['adapt'],
                       source=source, output_dir=args.output_dir)

    print(f"\n  ✅ Hoàn tất! Files trong: {args.output_dir}/\n")


if __name__ == '__main__':
    main()