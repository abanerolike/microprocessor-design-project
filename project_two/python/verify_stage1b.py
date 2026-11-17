"""Checks for the limiter methods: common start, solver tolerance, no effect below the limit."""
import numpy as np
import pandas as pd
import gfm_model as m

B = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, t_end=20.0, trip=3.3 / 80, cap=1.0 / 80)
HELD = B | dict(r=0.10, p0=0.9, imax_cont=1.2)
METHODS = {"sat": dict(method="sat"), "fb 0.2": dict(method="fb", ks=0.2),
           "fb 1.0": dict(method="fb", ks=1.0), "vi 0.3": dict(method="vi", kvi=0.3)}


def frame(**kw):
    return pd.DataFrame(m.simulate(**kw)[0], columns=m.COLS)


rows = []

# 1. Every method must start from the same still state
for name, meth in METHODS.items():
    pre = frame(**(HELD | meth)).query("t < 1.0")
    rows.append([f"pre-trip drift, {name}, |i1| [pu]", np.ptp(pre.i1), 1e-6, np.ptp(pre.i1) < 1e-6])

# 2. Solver tolerance on the adopted method
a, b = frame(**(HELD | METHODS["fb 0.2"])), frame(rtol=1e-8, **(HELD | METHODS["fb 0.2"]))
for col, tol in (("f", 1e-3), ("i1", 1e-3)):
    diff = abs(a[col].agg("max" if col == "i1" else "min") - b[col].agg("max" if col == "i1" else "min"))
    rows.append([f"fb 0.2, rtol 1e-6 vs 1e-8, {col} [extreme]", diff, tol, diff < tol])

# 3. Below the limit the extra terms must do nothing
ref = frame(**(B | dict(r=0.10)))
for name, meth in METHODS.items():
    diff = np.abs(frame(**(B | dict(r=0.10) | meth)).f.values - ref.f.values).max()
    rows.append([f"limit not reached, {name} vs sat, f [Hz]", diff, 1e-9, diff < 1e-9])

print(pd.DataFrame(rows, columns=["Check", "Difference", "Tolerance", "Pass"]).to_string(index=False))
