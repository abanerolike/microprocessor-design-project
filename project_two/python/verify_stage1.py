"""Checks for the stage 1 model. Each check prints one table row."""
import numpy as np
import pandas as pd
import gfm_model as m

B = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, t_end=20.0, trip=3.3 / 80, cap=1.0 / 80)
SLIP = B | dict(r=0.10, p0=0.9)


def swing_only(trip, H, D, R, K, Tg, cap, t_trip=1.0, t_end=20.0, dt=1e-3):
    """Independent grid check: plain Euler on the swing and governor equations, no inverter."""
    x = pm = 0.0
    fmin = 60.0
    for k in range(int(t_end / dt)):
        pm += dt / Tg * (-K / R * x - pm)
        if cap is not None:
            pm = min(pm, cap)
        x += dt / (2 * H) * (pm - (trip if k * dt >= t_trip else 0.0) - D * x)
        fmin = min(fmin, 60 * (1 + x))
    return fmin


def summary(o):
    d = pd.DataFrame(o, columns=m.COLS)
    return d.f.min(), d.i1.max(), d.shed_gw.iloc[-1], int(np.ptp(np.unwrap(d.dtheta)) // (2 * np.pi))


rows = []

# 1. Pre-trip state must not move
d = pd.DataFrame(m.simulate(**SLIP)[0], columns=m.COLS).query("t < 1.0")
rows.append(["pre-trip drift, f [Hz]", np.ptp(d.f), 1e-6, np.ptp(d.f) < 1e-6])

# 2. With r = 0 and UFLS off, the grid side must match the independent swing calculation
for trip in (1.4, 3.3):
    for cap in (None, 1.0):
        kw = dict(H=3.3, D=1.0, K=0.3, Tg=3.0, cap=None if cap is None else cap / 80)
        f1 = m.simulate(t_end=20.0, r=0.0, ufls=False, trip=trip / 80, **kw)[0][:, 1].min()
        f2 = swing_only(trip / 80, R=0.05, **kw)
        rows.append([f"r=0 vs swing-only, {trip} GW, cap {cap} [Hz]", abs(f1 - f2), 1e-3, abs(f1 - f2) < 1e-3])

# 3. Solver tolerance: 100x tighter on the slipping case
a = summary(m.simulate(**SLIP)[0])
b = summary(m.simulate(rtol=1e-8, **SLIP)[0])
rows.append(["rtol 1e-6 vs 1e-8, f min [Hz]", abs(a[0] - b[0]), 1e-3, abs(a[0] - b[0]) < 1e-3])
rows.append(["rtol 1e-6 vs 1e-8, max i1 [pu]", abs(a[1] - b[1]), 1e-3, abs(a[1] - b[1]) < 1e-3])

# 4. UFLS check period: 1.024 ms vs half of it
c = summary(m.simulate(seg=0.512e-3, **SLIP)[0])
rows.append(["UFLS 1.024 vs 0.512 ms, f min [Hz]", abs(a[0] - c[0]), 1e-2, abs(a[0] - c[0]) < 1e-2])
rows.append(["UFLS 1.024 vs 0.512 ms, shed [GW]", abs(a[2] - c[2]), 0.0, a[2] == c[2]])
rows.append(["UFLS 1.024 vs 0.512 ms, slips", abs(a[3] - c[3]), 0, a[3] == c[3]])

print(pd.DataFrame(rows, columns=["Check", "Difference", "Tolerance", "Pass"]).to_string(index=False))
