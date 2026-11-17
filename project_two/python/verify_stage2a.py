"""Stage 2a check: the 1 us discrete model against the stage 1b continuous reference (results CSV)."""
import time
from pathlib import Path
import numpy as np
import pandas as pd
import gfm_discrete as q

REF = pd.read_csv(Path(__file__).with_name("results") / "stage1b_metrics.csv").set_index("Case")
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
# cases that never settle (chattering or oscillating) are shown but not graded
UNGRADED = {"held, fb ks=1.0": HELD | dict(method="fb", ks=1.0),
            "held, vi kvi=0.3": HELD | dict(method="vi", kvi=0.3)}

q.simulate(t_end=0.01, **HELD)   # compile once
rows = []
for name, kw in (CASES | UNGRADED).items():
    t0 = time.time()
    st = q.simulate(**kw)[1]
    ref = REF.loc[name]
    df = abs(st["f min [Hz]"] - ref["f min [Hz]"])
    di = abs(st["max |i1| [pu]"] - ref["max |i1| [pu]"])
    de = st["GFM extra energy [GW s]"] - ref["GFM extra energy [GW s]"]
    dt = st["time over Imax(t)+0.5% [s]"] - ref["time over Imax(t)+0.5% [s]"]
    ok = (df < 1e-3 and di < 1e-3 and abs(de) < 0.01 and abs(dt) < 1e-3
          and st["pole slips"] == ref["pole slips"]
          and abs(st["UFLS shed [GW]"] - ref["UFLS shed [GW]"]) < 0.01)
    rows.append([name, st["f min [Hz]"], df, di, int(st["pole slips"]), int(ref["pole slips"]),
                 st["UFLS shed [GW]"], de, dt, time.time() - t0, "-" if name in UNGRADED else ok])

cols = ["Case", "f min 2a [Hz]", "|df min| [Hz]", "|d max i1| [pu]", "slips 2a", "slips ref",
        "shed 2a [GW]", "d energy [GW s]", "d over time [s]", "run [s]", "Pass"]
print(pd.DataFrame(rows, columns=cols).round(6).to_string(index=False))
