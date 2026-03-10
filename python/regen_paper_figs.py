#!/usr/bin/env python3
"""
regen_paper_figs.py — Tạo lại TẤT CẢ figures cho paper
════════════════════════════════════════════════════════

Chạy:
  python regen_paper_figs.py

Cần có sẵn trong cùng thư mục:
  - table2_data.csv         (từ bb84_table2.py)
  - [tuỳ chọn] FPGA per-qubit data files nếu muốn dùng data thật cho Fig 3

Output (trong thư mục Images/):
  - fig_qber_vs_turb_comparison.png   (Fig 2)
  - fig_qber_vs_snr.png              (Fig 3)
  - fig_skr_vs_turb.png              (Fig 4)
  - fig_timing_comparison.png        (Fig 5)
  - fig_sift_efficiency.png          (bonus)
"""

import csv, math, os
import numpy as np

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# ============================================================
# STYLE — IEEE publication, no titles, large fonts
# ============================================================
FIGW = 3.5          # IEEE single column width (inches)
FIGW2 = 7.16        # IEEE double column width (inches)

plt.rcParams.update({
    'font.family': 'serif',
    'font.size': 9,
    'axes.labelsize': 11,
    'legend.fontsize': 9,
    'xtick.labelsize': 9,
    'ytick.labelsize': 9,
    'lines.linewidth': 1.5,
    'lines.markersize': 6,
    'figure.dpi': 300,
    'savefig.bbox': 'tight',
    'savefig.pad_inches': 0.05,
})

C_FIXED = '#d62728'
C_ADAPT = '#1f77b4'
C_LIMIT = '#555555'
LBL_FIXED = 'Fixed'
LBL_ADAPT = 'Adaptive control'

# Output directory
OUT = 'Images'
os.makedirs(OUT, exist_ok=True)

# ============================================================
# LOAD TABLE II DATA
# ============================================================
rows = []
with open('table2_data.csv') as f:
    reader = csv.DictReader(f)
    for r in reader:
        r['level'] = int(r['level'])
        r['adaptive'] = r['adaptive'] == 'True'
        for k in ['qber', 'skr', 'sift_theory', 'sift_actual', 'p_fade']:
            r[k] = float(r[k])
        rows.append(r)

fixed = sorted([r for r in rows if not r['adaptive']], key=lambda x: x['level'])
adapt = sorted([r for r in rows if r['adaptive']], key=lambda x: x['level'])
levels = [r['level'] for r in fixed]
names = ['OFF', 'Weak', 'Mild', 'Mod.', 'Strong', 'Severe']


# ============================================================
# FIG 2: QBER vs Turbulence Level (Bar Chart)
# ============================================================
def gen_fig2():
    fig, ax = plt.subplots(figsize=(FIGW, 2.8))
    x = np.arange(len(levels))
    w = 0.35

    bars_f = ax.bar(x - w/2, [r['qber'] for r in fixed], w,
                    color=C_FIXED, label=LBL_FIXED, edgecolor='k', lw=0.4)
    bars_a = ax.bar(x + w/1.5, [r['qber'] for r in adapt], w,
                    color=C_ADAPT, label=LBL_ADAPT, edgecolor='k', lw=0.4)
    ax.axhline(11, color=C_LIMIT, ls='--', lw=1.2,
               label='BB84 security limit (11%)')

    for bars in [bars_f, bars_a]:
        for bar in bars:
            h = bar.get_height()
            if h > 0.3:
                ax.text(bar.get_x() + bar.get_width()/2, h + 0.3,
                        f'{h:.1f}', ha='center', va='bottom', fontsize=7)

    ax.set_xlabel('Turbulence Level')
    ax.set_ylabel('QBER (%)')
    ax.set_xticks(x)
    ax.set_xticklabels([f'L{l}\n{n}' for l, n in zip(levels, names)], fontsize=8)
    ax.legend(loc='upper left', framealpha=0.0, edgecolor='#ccc')
    ax.grid(True, alpha=0.3, axis='y')
    ax.set_ylim(0, 16)

    fig.tight_layout(pad=0.3)
    fig.savefig(f'{OUT}/fig_qber_vs_turb_comparison.png')
    plt.close(fig)
    print("  ✅ fig_qber_vs_turb_comparison.png")


# ============================================================
# FIG 3: QBER vs SNR — Level 3 + Level 4 (side-by-side)
# ============================================================
TURB_PARAMS = {
    3: {'alpha': 4.198, 'beta': 2.269, 'name': 'Level 3 (Moderate)'},
    4: {'alpha': 4.120, 'beta': 1.435, 'name': 'Level 4 (Strong)'},
}
FADE_THRESH = 38
WINDOW = 64

def simulate_and_window(alpha, beta, n, pz, seed):
    """Simulate FPGA behavior and compute sliding-window QBER vs SNR."""
    rng = np.random.RandomState(seed)
    records = []
    for _ in range(n):
        x = rng.gamma(alpha, 1.0 / alpha)
        y = rng.gamma(beta, 1.0 / beta)
        irr = min(int(x * y * 128), 255)
        ad = rng.randint(0, 2)
        ab = 0 if rng.random() < pz else 1
        bb = 0 if rng.random() < pz else 1
        if irr < FADE_THRESH:
            records.append({'lost': True})
        else:
            bm = 1 if ab == bb else 0
            records.append({'lost': False, 'basis_match': bm})

    snr_list, qber_list = [], []
    for start in range(0, len(records) - WINDOW + 1, WINDOW // 4):
        win = records[start:start + WINDOW]
        n_lost = sum(1 for r in win if r['lost'])
        n_ok = len(win) - n_lost
        snr = n_ok / len(win) * 255

        sifted_ok = sum(1 for r in win if not r['lost'] and r.get('basis_match'))
        sifted_lost = n_lost * 0.5
        errors_lost = sifted_lost * 0.5
        total_sifted = sifted_ok + sifted_lost
        total_errors = errors_lost
        qber = 100.0 * total_errors / total_sifted if total_sifted > 0 else 50

        snr_list.append(snr)
        qber_list.append(qber)
    return np.array(snr_list), np.array(qber_list)

def smooth_curve(x, y, n_bins=25, x_range=None):
    """Bin + cubic interpolation + Gaussian smooth."""
    if len(x) == 0:
        return np.array([]), np.array([])
    if x_range is None:
        x_range = (x.min(), x.max())

    from scipy.interpolate import interp1d
    from scipy.ndimage import gaussian_filter1d

    edges = np.linspace(x_range[0], x_range[1], n_bins + 1)
    centers = (edges[:-1] + edges[1:]) / 2
    means = np.full(n_bins, np.nan)
    for i in range(n_bins):
        mask = (x >= edges[i]) & (x < edges[i + 1])
        if mask.sum() >= 2:
            means[i] = np.mean(y[mask])
    valid = ~np.isnan(means)
    if valid.sum() < 3:
        return centers[valid], means[valid]

    f = interp1d(centers[valid], means[valid], kind='cubic',
                 fill_value='extrapolate')
    xs = np.linspace(centers[valid].min(), centers[valid].max(), 200)
    ys = gaussian_filter1d(np.clip(f(xs), 0, 50), sigma=3)
    return xs, ys

def gen_fig3():
    fig, axes = plt.subplots(1, 2, figsize=(FIGW2, 2.8), sharey=True)

    for idx, (lv, ax) in enumerate(zip([3, 4], axes)):
        p = TURB_PARAMS[lv]

        # Fixed (pz=0.5)
        snr_f, qber_f = simulate_and_window(
            p['alpha'], p['beta'], 5000, 0.5, 342 + lv * 100)
        # Adaptive (pz=0.8)
        snr_a, qber_a = simulate_and_window(
            p['alpha'], p['beta'], 5000, 0.8, 343 + lv * 100)

        x_range = (min(snr_f.min(), snr_a.min()) - 5,
                   max(snr_f.max(), snr_a.max()) + 5)

        # Scatter
        ax.scatter(snr_f, qber_f, s=6, c=C_FIXED, alpha=0.12, edgecolors='none')
        ax.scatter(snr_a, qber_a, s=6, c=C_ADAPT, alpha=0.12, edgecolors='none')

        # Smooth curves
        xs_f, ys_f = smooth_curve(snr_f, qber_f, x_range=x_range)
        xs_a, ys_a = smooth_curve(snr_a, qber_a, x_range=x_range)
        if len(xs_f) > 0:
            ax.plot(xs_f, ys_f, '-', color=C_FIXED, lw=2.0, label=LBL_FIXED)
        if len(xs_a) > 0:
            ax.plot(xs_a, ys_a, '-', color=C_ADAPT, lw=2.0, label=LBL_ADAPT)

        # BB84 limit
        ax.axhline(11, color=C_LIMIT, ls='--', lw=1.2, label='BB84 limit (11%)')

        # Stats box
        avg_f = np.mean(qber_f)
        avg_a = np.mean(qber_a)
        stats = (f'{LBL_FIXED}: {avg_f:.1f}%\n'
                 f'{LBL_ADAPT}: {avg_a:.1f}%\n'
                 f'$\\Delta$ = {avg_f - avg_a:+.1f}%')
        ax.text(0.97, 0.97, stats, transform=ax.transAxes, fontsize=7,
                va='top', ha='right',
                bbox=dict(boxstyle='round,pad=0.3', facecolor='white',
                          edgecolor='#ccc', alpha=0.9))

        # Level label (replaces title)
        ax.text(0.03, 0.03, p['name'], transform=ax.transAxes,
                fontsize=9, fontweight='bold', va='bottom', ha='left')

        ax.set_xlabel('SNR Proxy')
        ax.set_xlim(x_range)
        ax.set_ylim(0, 18)  # Cropped
        ax.grid(True, alpha=0.3)

        if idx == 0:
            ax.set_ylabel('QBER (%)')
            ax.legend(loc='upper left', fontsize=8,
                      framealpha=0.9, edgecolor='#ccc')

    fig.tight_layout(pad=0.3, w_pad=0.5)
    fig.savefig(f'{OUT}/fig_qber_vs_snr.png')
    plt.close(fig)
    print("  ✅ fig_qber_vs_snr.png")


# ============================================================
# FIG 4: SKR vs Turbulence Level (Line Chart)
# ============================================================
def gen_fig4():
    fig, ax = plt.subplots(figsize=(FIGW, 2.8))

    ax.plot(levels, [r['skr'] for r in fixed], 's-', color=C_FIXED, ms=7,
            label=LBL_FIXED, markerfacecolor='white', markeredgewidth=1.5)
    ax.plot(levels, [r['skr'] for r in adapt], 'o-', color=C_ADAPT, ms=7,
            label=LBL_ADAPT, markerfacecolor='white', markeredgewidth=1.5)

    ax.set_xlabel('Turbulence Level')
    ax.set_ylabel('Secure Key Rate (bits/pulse)')
    ax.set_xticks(levels)
    ax.set_xticklabels([f'L{l}\n{n}' for l, n in zip(levels, names)], fontsize=8)
    ax.legend(loc='upper right', framealpha=0.9, edgecolor='#ccc')
    ax.grid(True, alpha=0.3)
    ax.set_ylim(bottom=0)

    fig.tight_layout(pad=0.3)
    fig.savefig(f'{OUT}/fig_skr_vs_turb.png')
    plt.close(fig)
    print("  ✅ fig_skr_vs_turb.png")


# ============================================================
# FIG 5: Timing Comparison (Log Scale Bar Chart)
# ============================================================
def gen_fig5():
    modules = ['BB84\nEncode', 'OOK\nTX/RX', 'G-G\nChannel',
               'Channel\nMonitor', 'Adaptive\nControl']
    matlab_t = [4.0, 1.5, 117.8, 1.2, 1.4]
    fpga_t = [0.800, 3.200, 0.600, 0.408, 0.004]

    fig, ax = plt.subplots(figsize=(FIGW, 2.8))
    x = np.arange(len(modules))
    w = 0.35

    ax.bar(x - w/2, matlab_t, w, color=C_FIXED, label='MATLAB',
           edgecolor='k', lw=0.4)
    ax.bar(x + w/2, fpga_t, w, color=C_ADAPT, label='FPGA',
           edgecolor='k', lw=0.4)
    ax.set_yscale('log')
    ax.set_ylabel('Processing Time (ms)')
    ax.set_xticks(x)
    ax.set_xticklabels(modules, fontsize=8)
    ax.set_ylim(bottom=0.002, top=500)
    ax.legend(loc='upper right', framealpha=0.9, edgecolor='#ccc')
    ax.grid(True, alpha=0.3, which='both', axis='y')

    for i in range(len(modules)):
        if fpga_t[i] > 0 and matlab_t[i] > fpga_t[i]:
            sp = matlab_t[i] / fpga_t[i]
            ymax = max(matlab_t[i], fpga_t[i])
            ax.text(x[i], ymax * 1.5, f'{sp:.0f}×', ha='center',
                    fontsize=8, fontweight='bold', color='#2e7d32')

    fig.tight_layout(pad=0.3)
    fig.savefig(f'{OUT}/fig_timing_comparison.png')
    plt.close(fig)
    print("  ✅ fig_timing_comparison.png")


# ============================================================
# BONUS: Sifting Efficiency Bar Chart
# ============================================================
def gen_sift():
    fig, ax = plt.subplots(figsize=(FIGW, 2.8))
    x = np.arange(len(levels))
    w = 0.35

    ax.bar(x - w/2, [r['sift_actual'] for r in fixed], w,
           color=C_FIXED, label=LBL_FIXED, edgecolor='k', lw=0.4)
    ax.bar(x + w/2, [r['sift_actual'] for r in adapt], w,
           color=C_ADAPT, label=LBL_ADAPT, edgecolor='k', lw=0.4)
    ax.axhline(50, color=C_FIXED, ls=':', lw=0.8, alpha=0.5)
    ax.axhline(68, color=C_ADAPT, ls=':', lw=0.8, alpha=0.5)

    ax.set_xlabel('Turbulence Level')
    ax.set_ylabel('Sifting Efficiency (%)')
    ax.set_xticks(x)
    ax.set_xticklabels([f'L{l}\n{n}' for l, n in zip(levels, names)], fontsize=8)
    ax.legend(loc='upper left', framealpha=0.9, edgecolor='#ccc')
    ax.grid(True, alpha=0.3, axis='y')
    ax.set_ylim(35, 78)

    fig.tight_layout(pad=0.3)
    fig.savefig(f'{OUT}/fig_sift_efficiency.png')
    plt.close(fig)
    print("  ✅ fig_sift_efficiency.png")


# ============================================================
# MAIN
# ============================================================
if __name__ == '__main__':
    print("\n  Generating paper figures...")
    print(f"  Output: {OUT}/\n")

    gen_fig2()   # QBER bar chart
    gen_fig3()   # QBER vs SNR (Level 3 + 4)
    gen_fig4()   # SKR line chart
    gen_fig5()   # Timing comparison
    gen_sift()   # Sifting efficiency

    print(f"\n  ✅ Done! All figures in {OUT}/")
    print("  Copy vào thư mục Images/ của LaTeX project.\n")
