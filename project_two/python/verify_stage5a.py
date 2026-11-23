"""Stage 5a/5b checks of the switching model. Writes results/stage5a_runs.csv (every run with its settings)
and results/stage5a_checks.csv (each check, its error, the limit fixed before the runs, pass or fail).
Usage: python verify_stage5a.py  (about an hour on two cores)

Settings: vdc in pu of the phase peak (2.4 design and board default, 4.0 analysis), dead time and ticks in physical time,
F = plant 1 us, PWM ticks 20 ns (pw 50); R = plant 0.1 us, PWM ticks 20 ns (sub 10, pw 5);
late = the hardware order (the duty register loads last step's v1, the plant gets last step's mean voltage).
Adopted configuration: F, late, double update, dead time 2 us, vdc 2.4 (4.0 selectable). The required checks
are run on it at both vdc values (T0 and T2 at 4.0, where no duty clips); the
"explore" checks (other dead times, update methods, thresholds) are recorded but do not set the exit code.
Exit code 1 when a required check fails: compare the names of failed checks, not only their number.
"""
import sys
from multiprocessing import Pool
from pathlib import Path
import numpy as np
import pandas as pd
import gfm_discrete as q
import gfm_model as m
import gfm_pwm as w

OUT = Path(__file__).with_name("results")
HELD = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, trip=3.3 / 80, cap=1.0 / 80, r=0.10, p0=0.9, imax_cont=1.2)
CASES = {"sat": HELD, "fb": HELD | dict(method="fb", ks=0.2)}
TICK = 20e-9


def job(a):
    """One 20 s run. a = (case, mode, sub, pw, dead time [s], vdc, zth, upd, late, t_pre)."""
    case, mode, sub, pw, td, vdc, zth, upd, late, t_pre = a
    nd = int(round(td / (w.TS / sub / pw)))
    if abs(nd * w.TS / sub / pw - td) > 1e-12:
        raise ValueError("dead time is not a whole number of ticks")
    st, lg = w.simulate(sub=sub, mode=mode, vdc=vdc, nd=nd, zth=zth, pw=pw, upd=upd, late=late, t_pre=t_pre,
                        **CASES[case])
    if t_pre > 1.5:                                  # keep the logs for the abc check only
        lg["start"] = w.start(**CASES[case])[1]
        np.savez(OUT / "stage5a_t2_tmp.npz", v=lg["v"], thg=lg["thg"], i1=lg["i1"], vc=lg["vc"], c0=lg["start"])
    i1, pg = lg["i1"][:1_000_000], lg["pg"][500_000:1_000_000]
    per = i1.reshape(-1, 250)[2000:]                 # carrier periods in 0.5..1.0 s
    rip = np.sqrt(np.mean(np.abs(per - per.mean(1, keepdims=True)) ** 2))
    blk = lg["peak"][:1_000_000].reshape(-1, 5000).max(1)
    env = blk[100:].max()
    bad = np.nonzero(blk > 1.05 * env)[0]
    return dict(zip(["case", "mode", "sub", "pw", "dead [us]", "vdc [pu]", "zth [pu]", "upd", "late"],
                    [case, mode, sub, pw, td * 1e6, vdc, zth, upd, late])) | st | {
        "ripple rms 0.5-1 s [pu]": rip, "mean grid power 0.5-1 s [pu]": pg.mean(),
        "start transient over by [s]": (bad[-1] + 1) * 5e-3 if len(bad) else 0.0}


def key(case, mode=1, sub=1, pw=50, td=2e-6, vdc=2.4, zth=0.0, upd=2, late=True, t_pre=1.0):
    return (case, mode, sub, pw, td, vdc, zth, upd, late, t_pre)


def t1():
    rng = np.random.default_rng(1)
    e1 = e2 = 0.0
    for _ in range(10000):
        v, i = rng.normal(size=2) @ [1, 1j], rng.normal(size=2) @ [1, 1j]
        e = np.exp(1j * w.WB * rng.uniform(0, 20)) * w.A3
        vx = (v * e).real + rng.normal()             # with a common mode
        e1 = max(e1, abs(2 / 3 * np.sum(vx * np.conj(e)) - v) / abs(v))
        e2 = max(e2, abs(2 / 3 * np.sum(vx * (i * e).real) - (v * np.conj(i)).real) / max(abs(v) * abs(i), 1))
    return e1, e2


def t2():
    d = np.load(OUT / "stage5a_t2_tmp.npz")
    v, thg, i1, vc, c0 = d["v"], d["thg"], d["i1"], d["vc"], d["c0"]
    n = len(thg)
    z = w.lcl_abc(c0[0], c0[1], c0[2], v[:n], thg, 1, m.GRID | HELD)
    e = np.exp(1j * w.WB * np.arange(1, n) * w.TS)[:, None] * w.A3
    di = np.abs((i1[1:, None] * e).real - z[:-1, :, 0]).max()
    dv = np.abs((vc[1:, None] * e).real - z[:-1, :, 1]).max()
    s = slice(500_000, 1_000_000)
    p_dq = np.mean(2 / 3 * np.sum(v[s] * (i1[s, None] * e[s.start - 1:s.stop - 1]).real, 1))
    p_abc = np.mean(2 / 3 * np.sum(v[s] * z[s.start - 1:s.stop - 1, :, 0], 1))
    (OUT / "stage5a_t2_tmp.npz").unlink()
    return di, dv, abs(p_dq - p_abc) / abs(p_abc)


if __name__ == "__main__":
    runs = []
    for c in CASES:
        runs += [key(c, mode=0, pw=1, td=0.0, upd=0, late=False, vdc=4.0), key(c, mode=0, pw=1, td=0.0, upd=0, vdc=4.0),
                 key(c, mode=2, pw=1, td=0.0, upd=0, vdc=4.0)]                                # T0
        for v in (2.4, 4.0):
            for td in (0.0, 2e-6):
                runs += [key(c, td=td, vdc=v), key(c, td=td, sub=10, pw=5, vdc=v)]            # T3
            for z in (0.001, 0.01, 0.1):
                runs += [key(c, zth=z, vdc=v)]                                                # T4
            runs += [key(c, sub=10, pw=5, zth=0.01, vdc=v)]
        for u in (0, 1, 2):
            runs += [key(c, upd=u), key(c, mode=2, pw=1, td=0.0, upd=u, vdc=4.0), key(c, upd=u, vdc=4.0)]   # 5b
    runs = list(dict.fromkeys(runs))
    with Pool(2) as pool:
        res = pool.map(job, runs + [key("sat", t_pre=2.0, vdc=4.0)])
    T = pd.DataFrame(res[:-1])
    T.to_csv(OUT / "stage5a_runs.csv", index=False)
    R = {r: dict(zip(T.columns, row)) for r, row in zip(runs, T.itertuples(index=False))}

    rows = []

    def chk(kind, name, err, lim):
        rows.append([kind, name, err, lim, bool(err <= lim)])

    for c in CASES:
        ref = [q.simulate(nslow=1024, delay=d, **CASES[c])[1] for d in (0, 1, 2)]
        for r, d, n in [(key(c, mode=0, pw=1, td=0.0, upd=0, late=False, vdc=4.0), 0, "average = gfm_discrete"),
                        (key(c, mode=0, pw=1, td=0.0, upd=0, vdc=4.0), 1, "average, late = gfm_discrete delay 1"),
                        (key(c, mode=2, pw=1, td=0.0, upd=0, vdc=4.0), 2, "held duty, late (v1 and voltage) = delay 2")]:
            chk("required", f"T0 {c} {n}, f min [Hz]", abs(R[r]["f min [Hz]"] - ref[d]["f min [Hz]"]), 1e-9)
            chk("required", f"T0 {c} {n}, max |i1| [pu]", abs(R[r]["max |i1| [pu]"] - ref[d]["max |i1| [pu]"]), 1e-9)
        for v in (2.4, 4.0):
            for td in (2e-6, 0.0):
                kind = "required" if td else "explore"
                f, r = R[key(c, td=td, vdc=v)], R[key(c, td=td, sub=10, pw=5, vdc=v)]
                n = f"T3 {c} vdc {v} dead {td * 1e6:.0f} us, F vs R"
                chk(kind, n + ", f min [Hz]", abs(f["f min [Hz]"] - r["f min [Hz]"]), 2e-3)
                chk(kind, n + ", max phase |i1| [pu]", abs(f["max phase |i1| [pu]"] - r["max phase |i1| [pu]"]), 0.05)
                chk(kind, n + ", ripple rms [rel]",
                    abs(f["ripple rms 0.5-1 s [pu]"] / r["ripple rms 0.5-1 s [pu]"] - 1), 0.10)
                chk(kind, n + ", mean grid power [rel]",
                    abs(f["mean grid power 0.5-1 s [pu]"] / r["mean grid power 0.5-1 s [pu]"] - 1), 0.005)
                chk(kind, n + ", start transient over by [s]", f["start transient over by [s]"], 0.05)
            for z in (0.01, 0.001, 0.1):
                kind = "required" if z == 0.01 else "explore"
                f, g = R[key(c, vdc=v)], R[key(c, zth=z, vdc=v)]
                chk(kind, f"T4 {c} vdc {v} F zth 0 vs {z}, f min [Hz]", abs(f["f min [Hz]"] - g["f min [Hz]"]), 1e-3)
                chk(kind, f"T4 {c} vdc {v} F zth 0 vs {z}, max phase |i1| [pu]",
                    abs(f["max phase |i1| [pu]"] - g["max phase |i1| [pu]"]), 0.02)
            f, g = R[key(c, sub=10, pw=5, vdc=v)], R[key(c, sub=10, pw=5, zth=0.01, vdc=v)]
            chk("explore", f"T4 {c} vdc {v} R zth 0 vs 0.01, f min [Hz]", abs(f["f min [Hz]"] - g["f min [Hz]"]), 1e-3)
    e1, e2 = t1()
    chk("required", "T1 round trip [rel]", e1, 1e-12)
    chk("required", "T1 power identity [rel]", e2, 1e-12)
    di, dv, dp = t2()
    n = "T2 sat adopted F vdc 4.0, applied 1 us mean phase voltages, dq vs abc exact"
    chk("required", n + ", phase i1 [pu]", di, 0.01)
    chk("required", n + ", vc [pu]", dv, 0.01)
    chk("required", n + ", mean converter power [rel]", dp, 0.001)
    C = pd.DataFrame(rows, columns=["kind", "check", "error", "limit", "pass"])
    C.to_csv(OUT / "stage5a_checks.csv", index=False)
    pd.set_option("display.width", 220)
    print(C.to_string(index=False))
    req = C[C["kind"] == "required"]
    print(f"required {req['pass'].sum()}/{len(req)}, failed:", list(C.loc[~C["pass"], "check"]))
    sys.exit(0 if req["pass"].all() else 1)
