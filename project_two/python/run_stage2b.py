"""Stage 2b: board timing on top of 2a.
Grid model updated every 1.024 ms from the mean grid power (frequency held in between),
and the converter voltage applied 0, 1 or 2 steps (us) after its measurements.
"""
from pathlib import Path
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import gfm_discrete as q

OUT = Path(__file__).with_name("results")
B = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, trip=3.3 / 80, cap=1.0 / 80)
HIGH = B | dict(r=0.10, p0=0.9)
HELD = HIGH | dict(imax_cont=1.2)
CASES = {
    "held, no limit": HELD | dict(imax=10.0, imax_cont=10.0),
    "held, sat": HELD,
    "held, fb ks=0.05": HELD | dict(method="fb", ks=0.05),
    "held, fb ks=0.2": HELD | dict(method="fb", ks=0.2),
    "held, fb ks=0.5": HELD | dict(method="fb", ks=0.5),
    "held, vi kvi=0.1": HELD | dict(method="vi", kvi=0.1),
    "spec, sat": HIGH,
    "spec, fb ks=0.2": HIGH | dict(method="fb", ks=0.2),
    "one unit, sat": B | dict(r=0.0),
    "one unit, fb ks=0.2": B | dict(r=0.0, method="fb", ks=0.2),
    "not reached, sat": B | dict(r=0.10),
    "not reached, fb ks=0.2": B | dict(r=0.10, method="fb", ks=0.2),
}
DELAYS = [0, 1, 2]
KS = [0.05, 0.2, 0.5, 1.0, 2.0]

# 1. Same cases as 2a: does board timing change the outcome?
rows, recs = [], {}
for name, kw in CASES.items():
    ref = q.simulate(**kw)[1]
    for d in DELAYS:
        rec, st = q.simulate(nslow=1024, delay=d, **kw)
        recs[name, d] = rec
        df = st["f min [Hz]"] - ref["f min [Hz]"]
        di = st["max |i1| [pu]"] - ref["max |i1| [pu]"]
        same = st["pole slips"] == ref["pole slips"] and abs(st["UFLS shed [GW]"] - ref["UFLS shed [GW]"]) < 0.01
        dover = st["time over Imax(t)+0.5% [s]"] - ref["time over Imax(t)+0.5% [s]"]
        # fb is the adopted method: its current overshoot over Imax(t) must not grow compared with 2a.
        # This checks that the 2a behaviour is kept, not strict compliance at the 11 s limit step.
        dom = st["max over Imax(t) [pu]"] - ref["max over Imax(t) [pu]"]
        kept = dom < 1e-3 and dover < 1e-3 if kw.get("method") == "fb" else "-"
        rows.append([name, d, st["f min [Hz]"], df, di, st["max over Imax(t) [pu]"],
                     st["time over Imax(t)+0.5% [s]"], dover,
                     st["GFM extra energy [GW s]"] - ref["GFM extra energy [GW s]"],
                     st["pole slips"], st["UFLS shed [GW]"],
                     same and abs(df) < 0.01 and abs(di) < 0.01, kept])
cols = ["Case", "delay [us]", "f min 2b [Hz]", "d f min [Hz]", "d max i1 [pu]", "max over Imax(t) 2b [pu]",
        "time over 2b [s]", "d over time [s]", "d energy [GW s]", "slips 2b", "shed 2b [GW]",
        "Same outcome", "fb current performance preserved"]
t1 = pd.DataFrame(rows, columns=cols).round(6)
print(t1.to_string(index=False))
t1.to_csv(OUT / "stage2b_vs_2a.csv", index=False)

# 2. fb gain margin under board timing (held limit, the hardest case)
rows = []
for d in DELAYS:
    for ks in KS:
        st = q.simulate(nslow=1024, delay=d, **(HELD | dict(method="fb", ks=ks)))[1]
        rows.append([d, ks] + [st[k] for k in ["f min [Hz]", "max |i1| [pu]", "time over Imax(t)+0.5% [s]",
                                                "GFM extra energy [GW s]", "UFLS shed [GW]", "pole slips"]])
t2 = pd.DataFrame(rows, columns=["delay [us]", "ks", "f min [Hz]", "max |i1| [pu]", "time over Imax(t)+0.5% [s]",
                                 "GFM extra energy [GW s]", "UFLS shed [GW]", "pole slips"]).round(4)
print(t2.to_string(index=False))
t2.to_csv(OUT / "stage2b_ks.csv", index=False)

# 3. How much delay the loop takes before it breaks (well beyond the 1-2 us of the board)
rows = []
for d in [10, 100, 200, 240, 250]:
    for name in ["held, no limit", "held, sat", "held, fb ks=0.2"]:
        st = q.simulate(nslow=1024, delay=d, **CASES[name])[1]
        rows.append([d, name] + [st[k] for k in ["f min [Hz]", "max |i1| [pu]", "UFLS shed [GW]", "pole slips"]])
t3 = pd.DataFrame(rows, columns=["delay [us]", "Case", "f min [Hz]", "max |i1| [pu]", "UFLS shed [GW]",
                                 "pole slips"]).round(4)
print(t3.to_string(index=False))
t3.to_csv(OUT / "stage2b_delay_margin.csv", index=False)

# 4. fb 0.2 with the largest board delay, against sat
fig, ax = plt.subplots(2, 1, figsize=(9, 6), sharex=True)
for name in ["held, sat", "held, fb ks=0.2"]:
    d = pd.DataFrame(recs[name, 2], columns=q.REC)
    ax[0].plot(d.t, d.f, label=f"{name}, delay 2 us")
    ax[1].plot(d.t, d.i1, label=f"{name}, delay 2 us")
ax[1].axhline(1.2, color="gray", lw=0.8, ls=":")
ax[1].set_ylim(0, 2.0)
ax[0].set_ylabel("f [Hz]")
ax[1].set_ylabel("|i1| [pu]")
ax[1].set_xlabel("t [s]")
ax[0].legend(fontsize=8)
fig.tight_layout()
fig.savefig(OUT / "stage2b_delay2.png", dpi=150, bbox_inches="tight")
