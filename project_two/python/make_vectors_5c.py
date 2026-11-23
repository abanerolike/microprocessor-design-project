"""Stage 5c: test vectors for the PWM block (sim/vectors/pwm/), from the integer model with PWM.

  python make_vectors_5c.py          make: write every file (window starts only if they are missing)
  python make_vectors_5c.py check    check: make everything again in memory and compare with the files

Cases, each with vdc 2.4 pu (24) and 4.0 pu (40): held_fb, held_sat (trip B, 1.2 pu held: start, trip,
limit, and clip for held_sat_24), spec_fb, spec_sat (the step to 1.0 pu at 11 s), helda_fb, helda_sat
(trip A) and nolimit_fb, nolimit_sat (trip; with no limit sat and fb must give the same files, checked).
Start state: the board start file of stage 2d and the same 1 s integer warm-up, then PWM from step 0.
pwm_config.txt: the PWM constants and the start values the hardware loads (the start state's v1, the
duties made from it at angle 0 for each vdc, the gate commands and the current signs).
Window line k: k, the 22 state words, the 17 run-internal words, then the 15 PWM words (init flag,
active duty x3, pending duty x3, gate command x3, dead-time count x3, u re, u im) at the start of step k.
The *_sig line k: v1 of step k (made by the controller from state k), phi_k, the current signs used in
step k, the high-tick counts of step k, the new pending duty and the new u (both made in step k), and
cos, sin of phi_k (Q16, for loading a window).
Every window is replayed by a separate plain-Python PWM written from the stage 5c rules (pwm_ref) that
takes only line k, v1 and the step number and must give the PWM words of line k + 1 and the signals.
"""
import sys
from pathlib import Path
import numpy as np
import gfm_fixed as fx
import gfm_model as m
import schedule_2c4 as sg

ROOT = Path(__file__).resolve().parents[1] / "sim" / "vectors"
OUT = ROOT / "pwm"
STEPS = 2048
B = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, trip=3.3 / 80, cap=1.0 / 80, r=0.10, p0=0.9)
FB = dict(method="fb", ks=0.2)
NL = dict(imax=10.0, imax_cont=10.0)
CASES = {"held_fb": B | FB | dict(imax_cont=1.2), "held_sat": B | dict(imax_cont=1.2), "spec_fb": B | FB,
         "spec_sat": B, "helda_fb": B | FB | dict(imax_cont=1.2, trip=1.4 / 80),
         "helda_sat": B | dict(imax_cont=1.2, trip=1.4 / 80), "nolimit_fb": B | FB | NL, "nolimit_sat": B | NL}
PV = {"24": 1, "40": 2}
if sys.argv[1:] not in ([], ["check"]):
    raise SystemExit("usage: python make_vectors_5c.py [check]")
CHECK = sys.argv[1:] == ["check"]
DIFF = []
WIDTH = [32] * 18 + [40, 40, 32, 32] + [32, 28, 32] + [16] * 7 + [4] * 7          # state, run-internal
WIDTH += [4] + [16] * 6 + [4] * 3 + [8] * 3 + [34] * 2                              # PWM
SIG = [34, 34, 40, 4, 8, 8, 8, 16, 16, 16, 34, 34, 18, 18]


def emit(name, lines):
    text = "\n".join(lines) + "\n"
    f = OUT / name
    if not CHECK:
        f.write_text(text)
    elif not f.exists() or f.read_bytes().replace(b"\r\n", b"\n") != text.encode():
        DIFF.append(name)


def hx(v, bits):
    return format(int(v) & ((1 << bits) - 1), f"0{(bits + 3) // 4}x")


def setup(name):
    g = m.GRID | CASES[name]
    ki, kf = fx.consts(g)
    tab = fx.ufls_table()
    cap, p0 = round(g["cap"] * 2**fx.FX), round(g["p0"] * 2**fx.F)
    imx0, imxc = round(g["imax"] * 2**fx.F), round(g["imax_cont"] * 2**fx.F)
    s0 = np.array([int(v) for v in (ROOT / f"{name}_start.txt").read_text().split()], dtype=np.int64)
    s, _, _, pg0, _ = fx.run(s0, ki, kf, np.array([p0, 0, cap, imx0, imx0, 1 << 40, 1 << 40, 0]), 1_000_000, 0,
                             False, False, 1_000_000, tab, fx.aux0())
    kt = round(g["t_trip"] / fx.TS)
    sc = np.array([p0, round(g["trip"] * 2**fx.FX), cap, imx0, imxc, kt, kt + round(g["t_short"] / fx.TS), pg0],
                  dtype=np.int64)
    return ki, kf, sc, 1 if g["method"] == "fb" else 0, tab, s


def v1_of(st, ax, ki, kf, sc, meth, tab):
    G = sg.Graph()
    sg.step(G, list(st), list(ax[:17]), ki, kf, sc, meth, tab)
    return G.last["v1_r"], G.last["v1_i"]


def rs(v, n):
    return (v + (1 << (n - 1))) >> n


def pwm_ref(p, v1r, v1i, i1r, i1i, k, pv, start=False):
    """One step of the PWM from the stage 5c rules, plain integers. p = the 15 PWM words of line k."""
    p = list(p)
    kn = fx.KPH << -fx.KPF
    phk, ph1 = k * kn % (1 << fx.PH), (k + 1) * kn % (1 << fx.PH)

    def cs(ph):
        return fx.trig(ph)

    def dty(ph):
        a = max(min(rs(v1r, 12), 131071), -131072)
        b = max(min(rs(v1i, 12), 131071), -131072)
        c, s = cs(ph)
        wr, wi = rs(a * c - b * s, 16), rs(a * s + b * c, 16)
        h, hw = rs(wi * fx.H3, 17), rs(wr, 1)
        return [min(max(3125 + -((-q * int(fx.VK[pv])) >> 21), 0), 6250) for q in (wr, h - hw, -h - hw)]

    if p[0] == 1:
        d = dty(phk)
        q0 = 50 * k % 12500
        p[4:7], p[7:10], p[10:13], p[13:15], p[0] = d, [int(x > min(q0, 12500 - q0)) for x in d], [100] * 3, \
            [v1r, v1i], 0
        if start:
            return p
    if k % 125 == 0:
        p[1:4] = p[4:7]
    c, s = cs(phk)
    a, b = (max(min(rs(v, 14), 131071), -131072) for v in (i1r, i1i))
    r, i = rs(a * c - b * s, 16), rs(a * s + b * c, 16)
    ng = [int(r < 0), int(i * fx.H3 - r * 65536 < 0), int(-i * fx.H3 - r * 65536 < 0)]
    n = [0, 0, 0]
    for t in range(50):
        qq = (50 * k + t) % 12500
        cr = min(qq, 12500 - qq)
        for x in range(3):
            cm = int(p[1 + x] > cr)
            if cm != p[7 + x]:
                p[7 + x], p[10 + x] = cm, 0
            n[x] += cm if p[10 + x] >= 100 else ng[x]
            p[10 + x] = min(p[10 + x] + 1, 100)
    p[4:7] = dty(ph1)
    gr, gi = rs((2 * n[0] - n[1] - n[2]) * int(fx.U1[pv]), 6), rs((n[1] - n[2]) * int(fx.U2[pv]), 6)
    p[13], p[14] = rs(gr * c + gi * s, 3), rs(gi * c - gr * s, 3)
    return p, [v1r, v1i, phk, ng[0] + 2 * ng[1] + 4 * ng[2]] + n + p[4:7] + p[13:15] + list(cs(phk))


def first(name, pv, ki, kf, sc, meth, tab, s):
    """Window starts. held_*: the start (load at step 0), the trip, the first limiting, and for held_sat the
    first 1024 steps with a clipped duty applied (vdc 2.4 only), found by the integer run in 1024-step
    pieces. spec_*: the limit step at 11 s. helda_*, nolimit_*: the trip. Kept in <case>_<vdc>_windows.txt;
    check mode only reads it."""
    f = OUT / f"{name}_{pv}_windows.txt"
    if f.exists():
        return {a: int(b) for a, b in (line.split() for line in f.read_text().split("\n") if line)}
    if CHECK:
        raise FileNotFoundError(f)
    w = {"imax_step": int(sc[6]) - 1024} if name.startswith("spec") else {"trip": int(sc[5]) - 1024}
    if not name.startswith("held_"):
        f.write_text("".join(f"{a} {b}\n" for a, b in w.items()))
        return w
    w = {"start": 0} | w
    aux, s = fx.aux0(PV[pv]), s.copy()
    for _ in range(20_000_000 // 1024):
        k = int(aux[0])
        s, rec, st, _, aux = fx.run(s, ki, kf, sc, 1024, meth, True, True, 1, tab, aux, PV[pv])
        if "limit" not in w and k >= sc[5] and (rec[:, 3] > rec[:, 4] * (1 - 1 / 2048)).any():
            w["limit"] = k - 1024
        if name == "held_sat" and pv == "24" and "clip" not in w and st[11] > 0:
            w["clip"] = k - 1024
        if len(w) == (4 if name == "held_sat" and pv == "24" else 3):
            break
    f.write_text("".join(f"{a} {b}\n" for a, b in w.items()))
    return w


def window(name, pv, wname, k0, ki, kf, sc, meth, tab, s):
    s, _, _, _, aux = fx.run(s.copy(), ki, kf, sc, k0, meth, True, True, 1 << 30, tab, fx.aux0(PV[pv]), PV[pv])
    rows, sig = [], []
    for j in range(STEPS):
        rows.append(list(s[:22]) + list(aux))
        v1r, v1i = v1_of(s, aux, ki, kf, sc, meth, tab)
        p, sg_ = pwm_ref(aux[17:], v1r, v1i, int(s[0]), int(s[1]), k0 + j, PV[pv])
        s, _, _, _, aux = fx.run(s, ki, kf, sc, 1, meth, True, True, 1 << 30, tab, aux, PV[pv])
        if p != list(aux[17:]):                       # never keep a file the two PWMs do not agree on
            raise RuntimeError(f"{name} {pv} {wname}: model and replay differ after step {k0 + j}")
        sig.append(sg_)
    rows.append(list(s[:22]) + list(aux))
    text = [f"{r[22]} " + " ".join(hx(v, b) for v, b in zip(r[:22] + r[23:], WIDTH[:22] + WIDTH[23:])) for r in rows]
    emit(f"{name}_{pv}_{wname}.txt", text)
    emit(f"{name}_{pv}_{wname}_sig.txt", [" ".join(hx(v, b) for v, b in zip(r, SIG)) for r in sig])
    nclip = sum(1 for r in rows if r[39 + 1] in (0, 6250) or r[39 + 2] in (0, 6250) or r[39 + 3] in (0, 6250))
    loads = sum(1 for j in range(STEPS) if (k0 + j) % 125 == 0)
    print(f"{name} {pv} {wname:5s} steps {k0}..{k0 + STEPS}  replay = model, loads {loads}, "
          f"steps with a duty at 0 or 6250: {nclip}")


OUT.mkdir(parents=True, exist_ok=True)
ki, kf, sc, meth, tab, s = setup("held_fb")
lines = [f"{hx(v, 48)} {n}" for n, v in (("NH", fx.NH), ("ND", fx.ND), ("TPS", fx.TPS), ("H3", fx.H3),
                                          ("KN", fx.KPH << -fx.KPF))]
v1r, v1i = v1_of(s, fx.aux0(), ki, kf, sc, meth, tab)
lines += [f"{hx(v1r, 48)} v1_r0", f"{hx(v1i, 48)} v1_i0"]
for pv, j in PV.items():
    p = pwm_ref(fx.aux0(j)[17:], v1r, v1i, int(s[0]), int(s[1]), 0, j, start=True)
    _, sg0 = pwm_ref(fx.aux0(j)[17:], v1r, v1i, int(s[0]), int(s[1]), 0, j)
    lines += [f"{hx(fx.VK[j], 48)} VK_{pv}", f"{hx(fx.U1[j], 48)} U1_{pv}", f"{hx(fx.U2[j], 48)} U2_{pv}"]
    lines += [f"{hx(p[4 + x], 48)} duty{x}_{pv}" for x in range(3)]
    lines += [f"{hx(p[7 + x], 48)} cmd{x}_{pv}" for x in range(3)]
lines += [f"{hx(sg0[3], 48)} neg0"]
emit("pwm_config.txt", lines)
for name in CASES:
    ki, kf, sc, meth, tab, s = setup(name)
    for pv in PV:
        for wname, k0 in first(name, pv, ki, kf, sc, meth, tab, s).items():
            window(name, pv, wname, k0, ki, kf, sc, meth, tab, s)
for f in sorted(OUT.glob("nolimit_fb_*")):           # no limit: the fb term is always 0
    if not f.name.endswith("windows.txt") and f.read_bytes() != (OUT / f.name.replace("_fb_", "_sat_")).read_bytes():
        raise RuntimeError(f"{f.name}: sat and fb differ with no limit")
if CHECK:
    import hashlib
    h = hashlib.sha256(b"".join(f.read_bytes().replace(b"\r\n", b"\n") for f in sorted(OUT.glob("*.txt"))))
    print("hash of all PWM vector files:", h.hexdigest()[:12])
    print("files that differ:", ", ".join(DIFF) if DIFF else "none")
    sys.exit(1 if DIFF else 0)
