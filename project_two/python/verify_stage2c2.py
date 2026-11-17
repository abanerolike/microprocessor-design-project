"""Stage 2c-2 check: sin/cos ROM with interpolation, 1/sqrt by ROM seed and one Newton step.
1. ROM: worst error over 2^20 phases plus every address edge and the wrap from 2^40 - 1 to 0.
2. Limiter: every reachable (seed address, exponent) pair, so the bound is exhaustive, not sampled.
3. Limiter output: random wide references through both branches, exact integer check against Imax.
4. The closed-loop cases of 2c-1 with this arithmetic switched on.
"""
import numpy as np
import pandas as pd
from numba import njit
import gfm_fixed as fx
import verify_stage2c1 as v

fx.HW = True


@njit
def rom_sweep():
    err, nrm = 0.0, 0.0
    for k in range((1 << 20) + 3 * 1024 + 2):
        if k < 1 << 20:
            ph = k << 20
        elif k < (1 << 20) + 3 * 1024:
            j = k - (1 << 20)
            ph = ((j // 3) << 30) + (j % 3) - 1                 # one below, on and above each address
            ph &= (1 << 40) - 1
        else:
            ph = (1 << 40) - 1 if k % 2 == 0 else 0             # the wrap
        c, s = fx.trig(ph)
        a = ph * 2 * np.pi / 2.0**40
        err = max(err, abs(c / 2.0**16 - np.cos(a)), abs(s / 2.0**16 - np.sin(a)))
        nrm = max(nrm, abs((c * c + s * s) / 2.0**32 - 1))
    return err, nrm


@njit
def limit_sweep(imx):
    """Largest possible |i_lim| / Imax - 1 over each bucket of m2 that gives the same seed and exponent."""
    over, acc, mag_err = -1.0, 0.0, 0.0
    for e in range(-1, 4):                                      # m2 from 1/4 to 2^36: |i_raw| from 0.5 to 8 pu
        for u in range(1 << 17, 1 << 19):
            lo, hi = u << (11 + 2 * e), ((u + 1) << (11 + 2 * e)) - 1
            y, ee = fx.invsqrt(lo)
            scl = ((imx * y) >> 29) - fx.MARGIN
            if ee <= 0:
                scl = min(scl, 1 << (16 + ee))
            sc = scl / 2.0**(16 + ee)
            # the wide vector is up to 0.71 operand LSB longer than sqrt(m2); the last rounding adds 0.71 LSB at F = 28
            over = max(over, ((np.sqrt(hi / 2.0**28) + 0.71 / 2**14) * sc + 0.71 / 2.0**28) / (imx / 2.0**28) - 1)
            if lo > imx * imx >> 28:                                # accuracy only where the limiter really acts
                acc = min(acc, (np.sqrt(lo / 2.0**28) - 0.71 / 2**14) * sc / (imx / 2.0**28) - 1)
            mag_err = max(mag_err, abs(((lo * y) >> (17 + ee)) / 2.0**28 - np.sqrt(lo / 2.0**28)))
    return over, acc, mag_err


@njit
def limit_random(imx, n):
    """Wide (Q28) references, half of them within 4 operand LSB of imx, through the whole limiter path,
    both branches. Exact integer check of the final vector against imx."""
    np.random.seed(1)
    cnt = np.zeros(1, dtype=np.int64)
    bad, low, worst, near = 0, 0, -1.0, 4.0 / 2**14
    for k in range(n):
        lo, hi = (imx / 2.0**28 - near, imx / 2.0**28 + near) if k % 2 == 0 else (0.0, 7.99)
        r = lo + np.random.random() * (hi - lo)
        a = np.random.random() * 2 * np.pi
        ilr, ili, _, _ = fx.limit(int(r * np.cos(a) * 2**28), int(r * np.sin(a) * 2**28), imx, cnt)
        if ilr * ilr + ili * ili > imx * imx:
            bad += 1
        if np.hypot(ilr, ili) < min(r * 2**28, imx) * (1 - 5e-4) - 2:   # output much smaller than asked
            low += 1
        worst = max(worst, np.sqrt((ilr * ilr + ili * ili) / 2.0**56) / (imx / 2.0**28) - 1)
    return bad, low, worst


err, nrm = rom_sweep()
print(pd.DataFrame({"ROM check": ["max |sin, cos error|", "max |cos^2 + sin^2 - 1|"], "Value": [err, nrm]})
      .to_string(index=False))
rows = []
for imx in (1.0, 1.2):
    over, acc, mag_err = limit_sweep(round(imx * 2**28))
    bad, low, worst = limit_random(round(imx * 2**28), 10_000_000)
    rows.append([imx, over, acc, mag_err, bad, low, worst])
t = pd.DataFrame(rows, columns=["Imax [pu]", "worst |i_lim|/Imax - 1 (bound)", "worst accuracy",
                                "max |i_raw| error [pu]", "random over Imax (of 1e7)",
                                "random below min(|i_raw|, Imax) by > 0.05%", "random worst |i_lim|/Imax - 1"])
print(t.to_string(index=False, float_format=lambda x: f"{x:.3g}"))
print("ROM within 2e-5:", err < 2e-5, "| limiter never above Imax:", (t.iloc[:, 1] < 0).all() and (t.iloc[:, 4] == 0).all(),
      "| limiter accuracy within 0.05%:", (t.iloc[:, 2] > -5e-4).all() and (t.iloc[:, 5] == 0).all())
v.closed_loop("2c2")
