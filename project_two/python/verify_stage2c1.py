"""Stage 2c-1 check: integer model against the 2b float model (grid every 1024 steps, delay 0).
Stage 2c-2 reuses closed_loop() with the ROM and Newton arithmetic switched on.
"""
from pathlib import Path
import numpy as np
import pandas as pd
import gfm_model as m
import gfm_discrete as q
import gfm_fixed as fx

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
    "spec, sat": HIGH,
    "spec, fb ks=0.2": HIGH | dict(method="fb", ks=0.2),
    "one unit, sat": B | dict(r=0.0),
    "one unit, fb ks=0.2": B | dict(r=0.0, method="fb", ks=0.2),
    "not reached, sat": B | dict(r=0.10),
    "not reached, fb ks=0.2": B | dict(r=0.10, method="fb", ks=0.2),
}
SMALL = B | dict(trip=0.1 / 80, cap=None, r=0.10, p0=0.5, method="fb", ks=0.2)   # far from UFLS and the limit


def pg0_float(kw):
    """Pre-trip grid power of the 2b model, same steps as gfm_discrete.simulate."""
    g = m.GRID | kw
    s = m.unpack(m.settle(g)[0])
    c = np.array([s[k] for k in m.C_NAMES])
    rr = np.array([s[k] for k in m.R_NAMES])
    p0 = q.params(g | dict(t_trip=1e9, method="sat"))
    c, rr, _, _ = q.run(c, rr, p0, 0, 1_000_000, 0.0, False, False, 1_000_000, q.UFLS, 1, 0)
    return (np.exp(1j * rr[3]) * np.conj(c[2])).real


def closed_loop(tag):
    """Run every case on the integer model and the 2b float model, and grade with the fixed criteria."""
    rows = []
    for name, kw in CASES.items():
        rec_f, ref = q.simulate(nslow=1024, **kw)
        rec_x, st = fx.simulate(**kw)
        df = st["f min [Hz]"] - ref["f min [Hz]"]
        di = st["max |i1| [pu]"] - ref["max |i1| [pu]"]
        same = (st["pole slips"] == ref["pole slips"] and abs(st["UFLS shed [GW]"] - ref["UFLS shed [GW]"]) < 0.01
                and abs(df) < 0.01 and abs(di) < 0.01)
        if kw.get("method") == "fb":
            same = same and (st["max over Imax(t) [pu]"] - ref["max over Imax(t) [pu]"] < 1e-3
                             and st["time over Imax(t)+0.5% [s]"] - ref["time over Imax(t)+0.5% [s]"] < 1e-3)
        dop = max(abs(rec_x[0, 2] - rec_f[0, 2]), abs(st["pg0 [pu]"] - pg0_float(kw)))
        still = st["pre-trip f ptp [Hz]"] < 1e-4 and st["pre-trip |i1| ptp [pu]"] < 1e-4
        rows.append([name, st["f min [Hz]"], df, di, st["max over Imax(t) [pu]"] - ref["max over Imax(t) [pu]"],
                     st["GFM extra energy [GW s]"] - ref["GFM extra energy [GW s]"], st["pole slips"], st["UFLS shed [GW]"],
                     int(st["saturations"]), dop, st["pre-trip |i1| ptp [pu]"], st["pre-trip f ptp [Hz]"],
                     same and st["saturations"] == 0 and dop < 1e-3 and still])
    cols = ["Case", "f min 2c [Hz]", "d f min [Hz]", "d max i1 [pu]", "d max over [pu]", "d energy [GW s]",
            "slips 2c", "shed 2c [GW]", "saturations", "op point err [pu]", "pre |i1| ptp [pu]", "pre f ptp [Hz]", "Pass"]
    t1 = pd.DataFrame(rows, columns=cols)
    print(t1.to_string(index=False, float_format=lambda v: f"{v:.6g}"))
    t1.to_csv(OUT / f"stage{tag}_vs_2b.csv", index=False)

    # small disturbance: a model whose small gains rounded to zero would sit still and still pass the table above
    rec_f, ref = q.simulate(nslow=1024, **SMALL)
    rec_x, st = fx.simulate(**SMALL)
    resp = pd.DataFrame({
        "Response": ["f drop [Hz]", "|i1| rise [pu]"],
        "2b float": [60 - ref["f min [Hz]"], ref["max |i1| [pu]"] - rec_f[0, 2]],
        f"{tag} integer": [60 - st["f min [Hz]"], st["max |i1| [pu]"] - rec_x[0, 2]],
    })
    resp["Relative diff"] = resp[f"{tag} integer"] / resp["2b float"] - 1
    resp["Pass"] = resp["Relative diff"].abs() < 0.05
    print(resp.to_string(index=False, float_format=lambda v: f"{v:.6g}"))
    resp.to_csv(OUT / f"stage{tag}_small.csv", index=False)


if __name__ == "__main__":
    fx.HW = False       # 2c-1: sin/cos and 1/sqrt in floating point
    closed_loop("2c1")
