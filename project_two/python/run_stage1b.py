"""Stage 1b: limiter methods compared under the same current limit and the same trips."""
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import gfm_model as m

OUT = Path(__file__).with_name("results")

B = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, t_end=20.0, trip=3.3 / 80, cap=1.0 / 80)
HIGH = B | dict(r=0.10, p0=0.9)            # high pre-trip output, limit is reached
HELD = HIGH | dict(imax_cont=1.2)          # cause test: limit stays at 1.2
SAT = dict(method="sat")
FB = dict(method="fb", ks=0.2)
VI = dict(method="vi", kvi=0.3)

CASES = {
    "held, no limit": HELD | dict(imax=10.0, imax_cont=10.0),
    "held, sat": HELD | SAT,
    "held, fb ks=0.05": HELD | dict(method="fb", ks=0.05),
    "held, fb ks=0.2": HELD | FB,
    "held, fb ks=0.5": HELD | dict(method="fb", ks=0.5),
    "held, fb ks=1.0": HELD | dict(method="fb", ks=1.0),
    "held, vi kvi=0.1": HELD | dict(method="vi", kvi=0.1),
    "held, vi kvi=0.3": HELD | VI,
    "spec, sat": HIGH | SAT,
    "spec, fb ks=0.2": HIGH | FB,
    "one unit, sat": B | dict(r=0.0) | SAT,
    "one unit, fb ks=0.2": B | dict(r=0.0) | FB,
    "not reached, sat": B | dict(r=0.10) | SAT,
    "not reached, fb ks=0.2": B | dict(r=0.10) | FB,
    "not reached, vi kvi=0.3": B | dict(r=0.10) | VI,
}


def metrics(name, o, t_trip=1.0):
    d = pd.DataFrame(o, columns=m.COLS)
    dt = np.gradient(d.t)
    over = (d.i1 - d.imax).clip(lower=0)
    return {
        "Case": name,
        "f min [Hz]": d.f.min(),
        "max |i1| [pu]": d.i1.max(),
        "max over Imax(t) [pu]": over.max(),
        "time over Imax(t)+0.5% [s]": float((dt * (over > 0.005 * d.imax)).sum()),
        "GFM extra energy [GW s]": float((dt * d.p_gfm_gw)[d.t >= t_trip].sum()),
        "UFLS shed [GW]": d.shed_gw.iloc[-1],
        "f at 20 s [Hz]": d.f.iloc[-1],
        "pole slips": int(np.ptp(np.unwrap(d.dtheta)) // (2 * np.pi)),
    }


runs = {name: m.simulate(**kw)[0] for name, kw in CASES.items()}
table = pd.DataFrame([metrics(n, o) for n, o in runs.items()]).round(4)
print(table.to_string(index=False))
table.to_csv(OUT / "stage1b_metrics.csv", index=False)

# 1. Same limit, three methods, plus the unlimited reference
show = ["held, no limit", "held, sat", "held, fb ks=0.2", "held, vi kvi=0.3"]
fig, ax = plt.subplots(4, 1, figsize=(9, 11), sharex=True)
for name in show:
    d = pd.DataFrame(runs[name], columns=m.COLS)
    ls = "--" if "no limit" in name else "-"
    ax[0].plot(d.t, d.f, ls, label=name)
    ax[1].plot(d.t, d.i1, ls, label=name)
    ax[2].plot(d.t, np.degrees(np.unwrap(d.dtheta)), ls, label=name)
    ax[3].plot(d.t, d.p_gfm_gw, ls, label=name)
ax[1].axhline(1.2, color="gray", lw=0.8, ls=":")
ax[1].set_ylim(0, 2.0)
ax[2].set_ylim(-400, 400)
ax[0].set_ylabel("f [Hz]")
ax[1].set_ylabel("|i1| [pu]")
ax[2].set_ylabel("inverter - grid angle [deg]")
ax[3].set_ylabel("GFM extra [GW]")
ax[3].set_xlabel("t [s]")
ax[0].legend(fontsize=8)
fig.tight_layout()
fig.savefig(OUT / "stage1b_compare.png", dpi=150, bbox_inches="tight")

# 2. What the current reference is made of, with and without the feedback
fig, ax = plt.subplots(2, 1, figsize=(9, 6), sharex=True)
for a, name in zip(ax, ["held, sat", "held, fb ks=0.2"]):
    d = pd.DataFrame(runs[name], columns=m.COLS).query("t < 6")
    for col, lab in [("ref_p", "proportional"), ("ref_i", "integral"), ("ref_ff", "feedforward"), ("iref", "total")]:
        a.plot(d.t, d[col], label=lab)
    a.set_title(name)
    a.set_ylabel("|i1 ref| parts [pu]")
ax[0].legend(fontsize=8)
ax[1].set_xlabel("t [s]")
fig.tight_layout()
fig.savefig(OUT / "stage1b_ref_terms.png", dpi=150, bbox_inches="tight")
