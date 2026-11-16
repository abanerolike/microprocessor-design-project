"""Stage 1 runs: pre-trip steady state, then generator trips with and without GFM support."""
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import gfm_model as m

OUT = Path(__file__).with_name("results")   # works from any working directory

BASE = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, t_end=20.0)
A = dict(trip=1.4 / 80, cap=None)          # one 1.4 GW unit, reserve not capped
B = dict(trip=3.3 / 80, cap=1.0 / 80)      # 3.3 GW multi-unit trip, 1 GW reserve
CASES = {
    "A, no GFM": A | dict(r=0.0),
    "A, r=1.2%": A | dict(r=0.012),
    "A, r=10%": A | dict(r=0.10),
    "B, no GFM": B | dict(r=0.0),
    "B, r=1.2%": B | dict(r=0.012),
    "B, r=10%": B | dict(r=0.10),
    "B, r=10%, P0=0.9": B | dict(r=0.10, p0=0.9),
    "B, r=10%, P0=0.9, no limit": B | dict(r=0.10, p0=0.9, imax=10.0, imax_cont=10.0),
    "B, r=10%, P0=0.9, 1.2 held": B | dict(r=0.10, p0=0.9, imax_cont=1.2),   # cause test: no drop to 1.0
}


def metrics(name, o, t_trip=1.0):
    d = pd.DataFrame(o, columns=m.COLS)
    after = d[d.t >= t_trip]
    k = after.f.idxmin()
    f500 = np.interp(t_trip + 0.5, d.t, d.f)
    dt = np.gradient(d.t)
    return {
        "Case": name,
        "f min [Hz]": d.f.min(),
        "t at f min [s]": d.t[k],
        "RoCoF 0-500 ms [Hz/s]": (f500 - 60) / 0.5,
        "max |i1| [pu]": after.i1.max(),
        "time ref limited [s]": float((dt * d.limited).sum()),
        "time |i1|>1.2 [s]": float((dt * (d.i1 > 1.2)).sum()),
        "time |i1|>Imax(t) [s]": float((dt * (d.i1 > d.imax)).sum()),
        "final |i1 ref| [pu]": d.iref.iloc[-1],
        "max GFM extra [GW]": after.p_gfm_gw.max(),
        "UFLS shed [GW]": d.shed_gw.iloc[-1],
        "f at 20 s [Hz]": d.f.iloc[-1],
        "pole slips": int(np.ptp(np.unwrap(d.dtheta)) // (2 * np.pi)),
    }


runs = {name: m.simulate(**(BASE | kw))[0] for name, kw in CASES.items()}

# 1. Pre-trip check: everything should sit still before t = 1 s
pre = pd.DataFrame(runs["B, r=10%, P0=0.9"], columns=m.COLS).query("t < 1.0")
print(pd.DataFrame({
    "Quantity": ["f [Hz]", "|i1| [pu]", "p_grid [pu]", "|vc| [pu]"],
    "Max change before trip": [np.ptp(pre.f), np.ptp(pre.i1), np.ptp(pre.p_grid), np.ptp(pre.vc)],
}).to_string(index=False))

# 2. Trip results
table = pd.DataFrame([metrics(n, o) for n, o in runs.items()]).round(3)
print(table.to_string(index=False))
table.to_csv(OUT / "stage1_metrics.csv", index=False)

# 3. Frequency and current
fig, ax = plt.subplots(3, 1, figsize=(9, 9), sharex=True)
for name, o in runs.items():
    if name.startswith("A"):
        continue
    d = pd.DataFrame(o, columns=m.COLS)
    ls = "--" if "no limit" in name else "-"
    ax[0].plot(d.t, d.f, ls, label=name)
    ax[1].plot(d.t, d.i1, ls, label=name)
    ax[2].plot(d.t, d.p_gfm_gw, ls, label=name)
for y in (59.2, 59.0):
    ax[0].axhline(y, color="gray", lw=0.6, ls=":")
lim = pd.DataFrame(runs["B, r=10%, P0=0.9"], columns=m.COLS)
ax[1].plot(lim.t, lim.imax, color="gray", lw=0.8, ls=":", label="Imax(t), 1.2 then 1.0")
ax[0].set_ylabel("f [Hz]")
ax[1].set_ylabel("|i1| [pu]")
ax[2].set_ylabel("GFM extra [GW]")
ax[2].set_xlabel("t [s]")
ax[0].legend(fontsize=8)
ax[1].legend(handles=ax[1].lines[-1:], fontsize=8, loc="lower right")
fig.tight_layout()
fig.savefig(OUT / "stage1_trip_B.png", dpi=150, bbox_inches="tight")

fig, ax = plt.subplots(figsize=(9, 3))
ax.plot(pre.t, pre.f - 60)
ax.set_xlabel("t [s]")
ax.set_ylabel("f - 60 [Hz]")
ax.set_title("Before the trip (B, r=10%, P0=0.9)")
fig.savefig(OUT / "stage1_pretrip.png", dpi=150, bbox_inches="tight")
