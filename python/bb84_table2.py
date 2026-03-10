#!/usr/bin/env python3
"""
bb84_table2.py — Thu data cho Table II + Fig 2 + Fig 4 của paper
═════════════════════════════════════════════════════════════════

Chạy FPGA:
  python bb84_table2.py --port COM28 --batch 5000

Chạy simulation:
  python bb84_table2.py --simulate --batch 5000

Output:
  - table2_data.csv          : raw data
  - fig_qber_vs_turb.png     : Fig 2 (QBER bar chart)
  - fig_skr_vs_turb.png      : Fig 4 (SKR line chart)
  - fig_sift_efficiency.png  : Sifting efficiency
  - LaTeX table (in terminal)
"""

import sys, time, random, argparse, os, math, csv
import numpy as np

HAS_SERIAL = False
try:
    import serial; HAS_SERIAL = True
except ImportError: pass

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# ============================================================
TURB = {
    0: {'name':'OFF',      'alpha':1e6,   'beta':1e6,   'sw':'000', 'sigma_r2':0.0},
    1: {'name':'WEAK',     'alpha':11.651,'beta':10.122,'sw':'001', 'sigma_r2':0.2},
    2: {'name':'MILD',     'alpha':5.978, 'beta':4.398, 'sw':'010', 'sigma_r2':0.5},
    3: {'name':'MODERATE', 'alpha':4.198, 'beta':2.269, 'sw':'011', 'sigma_r2':1.2},
    4: {'name':'STRONG',   'alpha':4.120, 'beta':1.435, 'sw':'100', 'sigma_r2':3.0},
    5: {'name':'SEVERE',   'alpha':5.272, 'beta':1.134, 'sw':'101', 'sigma_r2':8.0},
}
FADE_THRESH = 38
F_EC = 1.16

# Basis bias per level for adaptive mode
ADAPTIVE_PZ = {0: 0.50, 1: 0.55, 2: 0.60, 3: 0.80, 4: 0.80, 5: 0.80}

def h2(x):
    if x <= 0 or x >= 1: return 0.0
    return -x * math.log2(x) - (1-x) * math.log2(1-x)

def compute_skr(qber_frac, sift_eff):
    if qber_frac >= 0.11: return 0.0
    if qber_frac < 1e-10: return sift_eff
    info = 1.0 - (1.0 + F_EC) * h2(qber_frac)
    return max(0, sift_eff * info)

def sift_efficiency(pz):
    return pz**2 + (1-pz)**2

# ============================================================
class FPGAConn:
    def __init__(self, port, baud=115200):
        self.ser = serial.Serial(port, baud, timeout=0.05)
        time.sleep(0.5); self.ser.reset_input_buffer()
    def echo_test(self):
        self.ser.reset_input_buffer()
        self.ser.write(bytes([0x80 | (1<<2)]))
        time.sleep(0.1)
        line = self.ser.readline().decode('ascii', errors='ignore')
        return line.startswith('@')
    def reset_stats(self):
        self.ser.write(bytes([0x01])); time.sleep(0.05); self.ser.reset_input_buffer()
    def collect(self, n, basis_pz=0.5, seed=42):
        rng = np.random.RandomState(seed)
        self.reset_stats()
        n_ok = n_lost = n_sifted = n_errors = 0
        t0 = time.perf_counter()
        for i in range(n):
            ad = rng.randint(0,2)
            ab = 0 if rng.random() < basis_pz else 1
            bb = 0 if rng.random() < basis_pz else 1
            self.ser.write(bytes([0x80|(ad<<2)|(ab<<1)|bb]))
            line = self.ser.readline().decode('ascii', errors='ignore')
            if line.startswith('@') and '*' in line:
                try:
                    p = line.strip()[1:line.strip().index('*')].split(',')
                    if len(p) >= 7:
                        bm = int(p[4]); de = int(p[5])
                        n_ok += 1
                        if bm: n_sifted += 1
                        if bm and de: n_errors += 1
                    else: n_lost += 1
                except: n_lost += 1
            else: n_lost += 1
            if (i+1)%500==0:
                print(f"\r    [{i+1}/{n}] {(i+1)/(time.perf_counter()-t0):.0f} q/s",end='',flush=True)
        dt = time.perf_counter()-t0
        print(f"\r    Xong: {n_ok} OK + {n_lost} lost = {n} | {n/dt:.0f} q/s | {dt:.1f}s" + " "*20)
        return n_ok, n_lost, n_sifted, n_errors
    def close(self): self.ser.close()

class SimConn:
    def __init__(self, alpha, beta):
        self.alpha, self.beta = alpha, beta
    def echo_test(self): return True
    def reset_stats(self): pass
    def collect(self, n, basis_pz=0.5, seed=42):
        rng = np.random.RandomState(seed)
        n_ok = n_lost = n_sifted = n_errors = 0
        for i in range(n):
            if self.alpha > 1e5: irr = 128
            else:
                x = rng.gamma(self.alpha, 1.0/self.alpha)
                y = rng.gamma(self.beta, 1.0/self.beta)
                irr = min(int(x*y*128), 255)
            ad = rng.randint(0,2)
            ab = 0 if rng.random() < basis_pz else 1
            bb = 0 if rng.random() < basis_pz else 1
            if irr < FADE_THRESH: n_lost += 1; continue
            n_ok += 1
            if ab == bb:
                n_sifted += 1
                # No errors outside fade on FPGA (flip disabled)
        print(f"    Xong: {n_ok} OK + {n_lost} lost = {n} (sim)")
        return n_ok, n_lost, n_sifted, n_errors
    def close(self): pass

# ============================================================
def compute_row(n_total, n_ok, n_lost, n_sifted, n_errors, basis_pz):
    """Compute QBER, SKR, Sift% from raw counts."""
    p_fade = n_lost / n_total if n_total > 0 else 0
    # QBER including lost contribution
    sifted_lost = n_lost * 0.5
    errors_lost = sifted_lost * 0.5
    total_sifted = n_sifted + sifted_lost
    total_errors = n_errors + errors_lost
    qber = total_errors / total_sifted if total_sifted > 0 else 0.5
    # Sifting efficiency (theoretical from basis bias)
    sift_eff = sift_efficiency(basis_pz)
    # SKR
    skr = compute_skr(qber, sift_eff)
    # Actual measured sift rate
    sift_actual = n_sifted / n_ok if n_ok > 0 else 0
    return {
        'qber': qber * 100,
        'skr': skr,
        'sift_theory': sift_eff * 100,
        'sift_actual': sift_actual * 100,
        'p_fade': p_fade * 100,
        'n_ok': n_ok, 'n_lost': n_lost,
        'n_sifted': n_sifted, 'n_errors': n_errors,
    }

# ============================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', help='COM port')
    ap.add_argument('--simulate', action='store_true')
    ap.add_argument('--batch', type=int, default=5000)
    ap.add_argument('--levels', default='0,1,2,3,4,5')
    ap.add_argument('--seed', type=int, default=42)
    ap.add_argument('--output-dir', default='.')
    args = ap.parse_args()

    levels = [int(x) for x in args.levels.split(',')]
    source = 'FPGA' if args.port else 'Sim'
    os.makedirs(args.output_dir, exist_ok=True)

    print(f"\n{'█'*60}")
    print(f"  Table II Data Collection — {source}")
    print(f"  Levels: {levels}, Batch: {args.batch}")
    print(f"{'█'*60}")

    rows = []

    for lv in levels:
        p = TURB[lv]
        print(f"\n{'━'*55}")
        print(f"  LEVEL {lv}: {p['name']} (σ²_R = {p['sigma_r2']})")
        print(f"{'━'*55}")

        for adaptive_on in [False, True]:
            label = "Adaptive" if adaptive_on else "Fixed"
            pz = ADAPTIVE_PZ[lv] if adaptive_on else 0.50
            seed = args.seed + lv*100 + (1 if adaptive_on else 0)

            print(f"\n  [{label}] pz={pz:.2f}")

            if args.port:
                sw1 = 1 if adaptive_on else 0
                turb_sw = p['sw'] if lv > 0 else '000'
                sw4 = 1 if lv > 0 else 0
                print(f"  ► SW[9]=1 SW[4]={sw4} SW[7:5]={turb_sw} SW[1]={sw1} SW[0]=0")
                print(f"  ► Nhấn KEY[3] (reset)")
                input(f"  ► ENTER...")
                conn = FPGAConn(args.port)
                if not conn.echo_test():
                    print("  ✗ Retry...")
                    input("  ENTER...")
                    if not conn.echo_test():
                        print("  ✗ Skip"); conn.close(); continue
                n_ok, n_lost, n_sifted, n_errors = conn.collect(args.batch, pz, seed)
                conn.close()
            else:
                conn = SimConn(p['alpha'], p['beta'])
                n_ok, n_lost, n_sifted, n_errors = conn.collect(args.batch, pz, seed)

            row = compute_row(args.batch, n_ok, n_lost, n_sifted, n_errors, pz)
            row['level'] = lv
            row['name'] = p['name']
            row['adaptive'] = adaptive_on
            row['basis_pz'] = pz
            rows.append(row)

            print(f"    QBER={row['qber']:.2f}%  SKR={row['skr']:.4f}  "
                  f"Sift={row['sift_actual']:.1f}% (theory {row['sift_theory']:.1f}%)  "
                  f"Fade={row['p_fade']:.1f}%")

    # ============================================================
    # Save CSV
    csv_path = os.path.join(args.output_dir, 'table2_data.csv')
    with open(csv_path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=[
            'level','name','adaptive','qber','skr',
            'sift_theory','sift_actual','p_fade','basis_pz',
            'n_ok','n_lost','n_sifted','n_errors'])
        w.writeheader()
        w.writerows(rows)
    print(f"\n  ✅ CSV: {csv_path}")

    # ============================================================
    # Print LaTeX Table II
    fixed = sorted([r for r in rows if not r['adaptive']], key=lambda x: x['level'])
    adapt = sorted([r for r in rows if r['adaptive']], key=lambda x: x['level'])

    print(f"\n{'='*65}")
    print(f"  LaTeX Table II")
    print(f"{'='*65}")
    print(r"\begin{tabular}{c|cc|cc|cc}")
    print(r"\hline")
    print(r" & \multicolumn{2}{c|}{\textbf{QBER (\%)}} & \multicolumn{2}{c|}{\textbf{SKR (b/pulse)}} & \multicolumn{2}{c}{\textbf{Sift (\%)}} \\")
    print(r"\textbf{Lv} & \textbf{Fix} & \textbf{Adp} & \textbf{Fix} & \textbf{Adp} & \textbf{Fix} & \textbf{Adp} \\")
    print(r"\hline")
    for f_row, a_row in zip(fixed, adapt):
        lv = f_row['level']
        skr_f = f"{f_row['skr']:.3f}" if f_row['skr'] > 0.001 else "0"
        skr_a = f"{a_row['skr']:.3f}" if a_row['skr'] > 0.001 else "0"
        sift_f = f"{f_row['sift_actual']:.1f}"
        sift_a = f"{a_row['sift_actual']:.1f}" if a_row['skr'] > 0 else "---"
        print(f"{lv} & {f_row['qber']:.1f} & {a_row['qber']:.1f} "
              f"& {skr_f} & {skr_a} & {sift_f} & {sift_a} \\\\")
    print(r"\hline")
    print(r"\end{tabular}")

    # ============================================================
    # Fig 2: QBER bar chart
    if len(fixed) > 0 and len(adapt) > 0:
        fig, ax = plt.subplots(figsize=(9, 5.5))
        x = np.arange(len(fixed))
        w = 0.35
        ax.bar(x - w/2, [r['qber'] for r in fixed], w, color='#dc2626',
               label='Fixed', edgecolor='k', lw=0.5)
        ax.bar(x + w/2, [r['qber'] for r in adapt], w, color='#2563eb',
               label='Adaptive', edgecolor='k', lw=0.5)
        ax.axhline(11, color='#888', ls='--', lw=1.5, label='BB84 Limit (11%)')
        ax.set_xlabel('Turbulence Level')
        ax.set_ylabel('QBER (%)')
        ax.set_title(f'QBER: Fixed vs Adaptive [{source}]')
        ax.set_xticks(x)
        ax.set_xticklabels([f"L{r['level']}\n{r['name']}" for r in fixed])
        ax.legend()
        ax.grid(True, alpha=0.3, axis='y')
        for bars in ax.containers[:2]:
            for bar in bars:
                h = bar.get_height()
                if h > 0.5:
                    ax.text(bar.get_x()+bar.get_width()/2, h+0.3,
                            f'{h:.1f}', ha='center', fontsize=8)
        fig.tight_layout()
        path = os.path.join(args.output_dir, 'fig_qber_vs_turb_comparison.png')
        fig.savefig(path, dpi=200, bbox_inches='tight')
        plt.close(fig)
        print(f"  ✅ {path}")

    # ============================================================
    # Fig 4: SKR vs turbulence
    if len(fixed) > 0 and len(adapt) > 0:
        fig, ax = plt.subplots(figsize=(9, 5.5))
        lvs = [r['level'] for r in fixed]
        ax.plot(lvs, [r['skr'] for r in fixed], 's-', color='#dc2626',
                ms=8, lw=2, label='Fixed')
        ax.plot(lvs, [r['skr'] for r in adapt], 'o-', color='#2563eb',
                ms=8, lw=2, label='Adaptive')
        ax.set_xlabel('Turbulence Level')
        ax.set_ylabel('Secure Key Rate (bits/pulse)')
        ax.set_title(f'SKR: Fixed vs Adaptive [{source}]')
        ax.set_xticks(lvs)
        ax.set_xticklabels([f"L{r['level']}\n{r['name']}" for r in fixed])
        ax.legend()
        ax.grid(True, alpha=0.3)
        ax.set_ylim(bottom=0)
        fig.tight_layout()
        path = os.path.join(args.output_dir, 'fig_skr_vs_turb.png')
        fig.savefig(path, dpi=200, bbox_inches='tight')
        plt.close(fig)
        print(f"  ✅ {path}")

    # ============================================================
    # Sifting efficiency bar chart
    if len(fixed) > 0 and len(adapt) > 0:
        fig, ax = plt.subplots(figsize=(9, 5.5))
        x = np.arange(len(fixed))
        w = 0.35
        ax.bar(x - w/2, [r['sift_actual'] for r in fixed], w, color='#dc2626',
               label='Fixed (measured)', edgecolor='k', lw=0.5)
        ax.bar(x + w/2, [r['sift_actual'] for r in adapt], w, color='#2563eb',
               label='Adaptive (measured)', edgecolor='k', lw=0.5)
        ax.axhline(50, color='#dc2626', ls=':', lw=1, alpha=0.5)
        ax.axhline(68, color='#2563eb', ls=':', lw=1, alpha=0.5, label='80% Z-bias (68%)')
        ax.set_xlabel('Turbulence Level')
        ax.set_ylabel('Sifting Efficiency (%)')
        ax.set_title(f'Sifting Efficiency [{source}]')
        ax.set_xticks(x)
        ax.set_xticklabels([f"L{r['level']}\n{r['name']}" for r in fixed])
        ax.legend(fontsize=9)
        ax.grid(True, alpha=0.3, axis='y')
        ax.set_ylim(35, 80)
        fig.tight_layout()
        path = os.path.join(args.output_dir, 'fig_sift_efficiency.png')
        fig.savefig(path, dpi=200, bbox_inches='tight')
        plt.close(fig)
        print(f"  ✅ {path}")

    print(f"\n  ✅ Hoàn tất!\n")

if __name__ == '__main__':
    main()
