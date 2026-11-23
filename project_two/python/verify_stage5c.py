"""Stage 5c: integer PWM model (gfm_fixed, pv 1 / 2) against the floating-point PWM model (gfm_pwm) in the
adopted configuration: 20 ns ticks, plant 1 us, v1 and voltage each one step late, double update, dead time
2 us. Cases: trip A and B, Imax held at 1.2 pu / SPEC (1.0 pu after 10 s) / no limit, sat and fb, vdc 2.4 and
4.0 pu (24 runs per model), 20 s, all from the common continuous settle. The integer average model (pv 0)
runs too, so the PWM - average difference (model make-up) is kept apart from the float - integer one (method).
Writes results/stage5c_runs.csv and results/stage5c_checks.csv.
Required, per run (limits fixed before the runs): same UFLS shed (to 0.01 GW, so the same stages: the
integer model holds a stage as round(0.06 2^31), 1e-8 GW off the float value), |f min difference| < 0.01 Hz,
|max |i1| difference| < 0.01 pu, no saturation in the integer model; with no limit, sat and fb identical in
each model (on the five metrics above, not on every state). Recorded only: pole slips and clipped-duty
time of both models, and PWM minus average.
Usage: python verify_stage5c.py   (exit code 1 when a required check fails)
"""
import sys
from multiprocessing import Pool
from pathlib import Path
import pandas as pd
import gfm_fixed as fx
import gfm_pwm as w

OUT = Path(__file__).with_name("results")
B = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, trip=3.3 / 80, cap=1.0 / 80, r=0.10, p0=0.9)
LIM = {"held": dict(imax_cont=1.2), "spec": {}, "nolimit": dict(imax=10.0, imax_cont=10.0)}
FB = dict(method="fb", ks=0.2)
CASES = {f"{lim}{t}_{m}": B | kw | (dict(trip=1.4 / 80) if t else {}) | (FB if m == "fb" else {})
         for t in ("", "a") for lim, kw in LIM.items() for m in ("sat", "fb")}
KEYS = ["f min [Hz]", "max |i1| [pu]", "UFLS shed [GW]", "pole slips", "clipped time [s]"]


def job(a):
    case, vdc, model = a
    if model == "float":
        st, _ = w.simulate(sub=1, mode=1, vdc=vdc, nd=100, pw=50, upd=2, late=True, **CASES[case])
    else:
        _, st = fx.simulate(pv=0 if model == "average" else {2.4: 1, 4.0: 2}[vdc], **CASES[case])
        st["clipped time [s]"] = st.get("duty clipped [s]", 0.0)
    return dict(case=case, **{"vdc [pu]": vdc}, model=model, **{k: float(st[k]) for k in KEYS},
                saturations=float(st.get("saturations", 0)))


if __name__ == "__main__":
    runs = [(c, v, mdl) for c in CASES for v in (2.4, 4.0) for mdl in ("float", "integer")]
    with Pool(2) as pool:
        T = pd.DataFrame(pool.map(job, runs + [(c, 0.0, "average") for c in CASES]))
    T.to_csv(OUT / "stage5c_runs.csv", index=False)

    def row(c, v, mdl):
        return T[(T.case == c) & (T["vdc [pu]"] == v) & (T.model == mdl)].iloc[0]

    rows = []
    for c in CASES:
        a = row(c, 0.0, "average")
        for v in (2.4, 4.0):
            f, i = row(c, v, "float"), row(c, v, "integer")
            n = f"{c} vdc {v}"
            sh = abs(round(f["UFLS shed [GW]"], 2) - round(i["UFLS shed [GW]"], 2))
            rows += [["required", n + ", UFLS shed [GW]", sh, 0.0],
                     ["required", n + ", f min [Hz]", abs(f["f min [Hz]"] - i["f min [Hz]"]), 0.01],
                     ["required", n + ", max |i1| [pu]", abs(f["max |i1| [pu]"] - i["max |i1| [pu]"]), 0.01],
                     ["required", n + ", integer saturations", i["saturations"], 0.0],
                     ["record", n + ", pole slips float / integer",
                      f"{f['pole slips']:.0f} / {i['pole slips']:.0f}", ""],
                     ["record", n + ", clipped time float / integer [s]",
                      f"{f['clipped time [s]']:.4f} / {i['clipped time [s]']:.4f}", ""],
                     ["record", n + ", integer PWM - average: f min [Hz], max |i1| [pu], shed [GW]",
                      f"{i['f min [Hz]'] - a['f min [Hz]']:+.4f}, {i['max |i1| [pu]'] - a['max |i1| [pu]']:+.4f}, "
                      f"{i['UFLS shed [GW]'] - a['UFLS shed [GW]']:+.2f}", ""]]
    for t in ("", "a"):
        for v in (2.4, 4.0):
            for mdl in ("float", "integer"):
                s, b = row(f"nolimit{t}_sat", v, mdl), row(f"nolimit{t}_fb", v, mdl)
                d = max(abs(s[k] - b[k]) for k in KEYS)
                rows.append(["required", f"nolimit{t} vdc {v} {mdl}: sat = fb (largest difference)", d, 0.0])
    C = pd.DataFrame(rows, columns=["kind", "check", "error", "limit"])
    req = C["kind"] == "required"
    C["pass"] = [float(e) <= float(lm) if k == "required" else "" for k, e, lm in zip(C.kind, C.error, C.limit)]
    C.to_csv(OUT / "stage5c_checks.csv", index=False)
    pd.set_option("display.width", 220)
    pd.set_option("display.max_colwidth", 90)
    print(T.to_string(index=False))
    print(C.to_string(index=False))
    bad = [c for c, k, p in zip(C.check, C.kind, C["pass"]) if k == "required" and not p]
    print(f"required {req.sum() - len(bad)}/{req.sum()}, failed:", bad)
    sys.exit(1 if bad else 0)
