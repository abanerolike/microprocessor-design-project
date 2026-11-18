"""Stage 2d: test vectors for the VHDL testbenches.

Everything a run needs is written as integers, so the testbench and any later Python run start from the
same bits: constants, the two ROMs, the scenario, the start state and the run-internal state (power sum,
UFLS counters and flags, step number). The float settle is done once; its integer result is kept in
<case>_start.txt and read back on every later run, so the vectors do not depend on the machine.

  python make_vectors_2d.py          make: write every file (the start state only if it is missing)
  python make_vectors_2d.py check    check: read the start states and window list, make everything again
                                     in memory and compare with the files on disk; nothing is written and
                                     no floating-point settle runs

Vector line k = the state at the start of step k, then the run-internal state (input k -> output k+1).
The last line of a window is the state after its last step. The *_sig file has the main node values of
the same step from the operation graph of stage 2c-4.
"""
import hashlib
import sys
from pathlib import Path
import numpy as np
import gfm_fixed as fx
import gfm_model as m
import schedule_2c4 as sg

OUT = Path(__file__).resolve().parents[1] / "sim" / "vectors"
STEPS = 2048
B = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, trip=3.3 / 80, cap=1.0 / 80, r=0.10, p0=0.9)
CASES = {
    "held_fb": B | dict(imax_cont=1.2, method="fb", ks=0.2),
    "held_sat": B | dict(imax_cont=1.2),
    "spec_fb": B | dict(method="fb", ks=0.2),
    "nolimit_fb": B | dict(imax=10.0, imax_cont=10.0, method="fb", ks=0.2),
}
# state words without dth (simulation only) and their bit widths
WIDTH = [32] * 18 + [40, 40, 32, 32]
if sys.argv[1:] not in ([], ["check"]):                # a typo must not fall back to writing the reference files
    raise SystemExit("usage: python make_vectors_2d.py [check]")
CHECK = sys.argv[1:] == ["check"]
DIFF = []
SIG = [("v1_r", 34), ("v1_i", 34), ("il_r", 32), ("il_i", 32), ("lim", 2), ("exc", 33), ("dm", 18),
       ("inc", 26), ("incg", 25), ("pg", 18), ("th_c", 18), ("th_s", 18), ("thg_c", 18), ("thg_s", 18),
       ("ir_r", 32), ("ir_i", 32), ("wm1", 27), ("xw_r", 31), ("xw_i", 31), ("uv1_r", 24), ("uv1_i", 24)]


def emit(name, lines):
    """Write the file, or in check mode compare it with the one on disk."""
    text = "\n".join(lines) + "\n"
    f = OUT / name
    if not CHECK:
        f.write_text(text)
    elif not f.exists() or f.read_bytes().replace(b"\r\n", b"\n") != text.encode():
        DIFF.append(name)


def hx(v, bits):
    return format(int(v) & ((1 << bits) - 1), f"0{(bits + 3) // 4}x")


def setup(name, kw):
    """Checked scenario, constants, and the integer start state after the 1 s integer warm-up."""
    g = m.GRID | kw
    for v in (g["imax"], g["imax_cont"]):
        if not (v in (1.0, 1.2) or v >= 2.0):
            raise ValueError(f"Imax {v} pu: not verified for the integer limiter")
    ki, kf = fx.consts(g)
    tab = fx.ufls_table()
    cap, p0 = round(g["cap"] * 2**fx.FX), round(g["p0"] * 2**fx.F)
    imx0, imxc = round(g["imax"] * 2**fx.F), round(g["imax_cont"] * 2**fx.F)
    f = OUT / f"{name}_start.txt"
    if not f.exists():                               # the only floating-point step, done once
        if CHECK:
            raise FileNotFoundError(f)
        f.write_text("\n".join(str(v) for v in fx.to_int(m.unpack(m.settle(g)[0]))) + "\n")
    s0 = np.array([int(v) for v in f.read_text().split()], dtype=np.int64)
    s, _, _, pg0, _ = fx.run(s0, ki, kf, np.array([p0, 0, cap, imx0, imx0, 1 << 40, 1 << 40, 0]), 1_000_000,
                             0, False, False, 1_000_000, tab, fx.aux0())
    kt = round(g["t_trip"] / fx.TS)
    sc = np.array([p0, round(g["trip"] * 2**fx.FX), cap, imx0, imxc, kt, kt + round(g["t_short"] / fx.TS), pg0],
                  dtype=np.int64)
    meth = 1 if g["method"] == "fb" else 0
    lines = [f"{hx(v, 48)} {n}" for n, v in zip(fx.NAMES, ki)] + [f"{hx(v, 48)} F_{n}" for n, v in zip(fx.NAMES, kf)]
    lines += [f"{hx(v, 48)} {n}" for n, v in (("PH", fx.PH), ("KPH", fx.KPH), ("KPF", fx.KPF), ("MARGIN", fx.MARGIN),
                                             ("method_fb", meth), ("limit_enabled", int(g["imax"] < 2.0)))]
    lines += [f"{hx(v, 48)} {n}" for n, v in zip(["p0", "trip", "cap", "imax0", "imax_cont", "k_trip", "k_short", "pg0"], sc)]
    lines += [f"{hx(v, 48)} ufls{j}_{c}" for j, row in enumerate(tab) for c, v in zip(("x", "ticks", "shed"), row)]
    emit(f"{name}_config.txt", lines)
    return g, ki, kf, sc, meth, tab, s


def cross(ki, kf, sc, meth, tab, s):
    """First grid update where x drops through the first UFLS threshold, from the integer run alone.
    The window ends its first 1023 steps right there, so old and new x lie on both sides of it."""
    aux = fx.aux0()
    for _ in range(20_000_000 // 1024):                # the 20 s run
        xo = s[20]
        s, _, _, _, aux = fx.run(s, ki, kf, sc, 1024, meth, True, True, 1 << 30, tab, aux)
        if s[20] < tab[0, 0] <= xo:
            return int(aux[0]) - 1024
    raise RuntimeError("no UFLS threshold crossing within 20 s")


def excess(ki, kf, sc, meth, tab, s, k0):
    """First window from step k0 on where |i_raw| - Imax stays above 0 for all 2048 steps, so the fb term
    ks exc acts on every step. Steps the graph one step at a time (exc is a node value, not a state)."""
    s, _, _, _, aux = fx.run(s, ki, kf, sc, k0, meth, True, True, 1 << 30, tab, fx.aux0())
    G, st, ax, n = sg.Graph(), list(s), list(aux), 0
    for k in range(k0, k0 + 200_000):
        st, ax = sg.step(G, st, ax, ki, kf, sc, meth, tab)
        n = n + 1 if G.last["exc"] > 0 else 0
        if n == STEPS:
            return k - STEPS + 1
    raise RuntimeError("no window with exc > 0 on every step within 200,000 steps of the limit window")


def windows(name, g, sc, ki, kf, meth, tab, s):
    """Start steps of the windows: before the trip, the trip, first limiting, UFLS and the limit step at 11 s,
    plus the first UFLS threshold crossing for held_sat and the first fb-active window for held_fb. Found
    once and kept in <case>_windows.txt; later runs only read that file, and check mode never writes it."""
    f = OUT / f"{name}_windows.txt"
    if f.exists():
        w = {a: int(b) for a, b in (line.split() for line in f.read_text().split("\n") if line)}
        if CHECK or ("cross" in w or name != "held_sat") and ("excess" in w or name != "held_fb"):
            return w
        if name == "held_sat":
            w["cross"] = cross(ki, kf, sc, meth, tab, s.copy())
        else:
            w["excess"] = excess(ki, kf, sc, meth, tab, s.copy(), w["limit"])
        f.write_text("".join(f"{a} {b}\n" for a, b in w.items()))
        return w
    if CHECK:
        raise FileNotFoundError(f)
    rec, _ = fx.simulate(**CASES[name])              # 1.024 ms records, only to find where things happen
    kt, ks = int(sc[5]), int(sc[6])
    w = {"pretrip": 0, "trip": kt - 1024}
    if g["imax"] < 2.0:
        hit = np.flatnonzero(rec[:, 3] > rec[:, 4] * (1 - 1 / 2048))
        if hit.size:
            w["limit"] = int(round(rec[hit[0], 0] / fx.TS)) - 1024
    shed = np.flatnonzero(rec[:, 7] > 0)
    if shed.size:
        w["ufls"] = int(round(rec[shed[0], 0] / fx.TS)) - 1024
    if g["imax_cont"] != g["imax"]:
        w["imax_step"] = ks - 1024
    if name == "held_sat":
        w["cross"] = cross(ki, kf, sc, meth, tab, s.copy())
    if name == "held_fb":
        w["excess"] = excess(ki, kf, sc, meth, tab, s.copy(), w["limit"])
    f.write_text("".join(f"{a} {b}\n" for a, b in w.items()))
    return w


def write_window(name, wname, k_start, ki, kf, sc, meth, tab, s_base):
    s, _, _, _, aux = fx.run(s_base.copy(), ki, kf, sc, k_start, meth, True, True, 1 << 30, tab, fx.aux0())
    G = sg.Graph()
    st, ax = list(s), list(aux)
    rows, sig = [], []
    for _ in range(STEPS):
        rows.append(st[:22] + ax)
        st, ax = sg.step(G, st, ax, ki, kf, sc, meth, tab)
        sig.append([G.last[n] for n, _ in SIG])
    rows.append(st[:22] + ax)
    ref, _, _, _, ref_aux = fx.run(s.copy(), ki, kf, sc, STEPS, meth, True, True, 1 << 30, tab, aux)
    if list(ref[:22]) + list(ref_aux) != rows[-1]:     # never keep an answer file the model does not agree with
        raise RuntimeError(f"{name} {wname}: graph and model differ after step {k_start + STEPS - 1}")
    nu = tab.shape[0]
    wid = WIDTH + [32, 28, 32] + [16] * nu + [4] * nu
    text = [f"{r[22]} " + " ".join(hx(v, b) for v, b in zip(r[:22] + r[23:], wid[:22] + wid[23:])) for r in rows]
    emit(f"{name}_{wname}.txt", text)
    emit(f"{name}_{wname}_sig.txt", [" ".join(hx(v, b) for v, (_, b) in zip(r, SIG)) for r in sig])


def limiter_cases():
    """Boundary cases of the current limiter, for its own testbench: the decision threshold below, at and
    above (exactly at it only exists for 1.0 pu), operand rounding, zero, each exponent change of the
    normalizer, all four quadrants, no-limit mode, and random inputs. Imax alternates between cases.
    Line: Imax (Q28), en, ir re, ir im, then the expected lim, exc, il re, il im."""
    rng, cnt, out = np.random.default_rng(7), np.zeros(1, dtype=np.int64), []
    for imx_pu in (1.0, 1.2, 10.0):
        imx = round(imx_pu * 2**fx.F)
        hw = imx if imx_pu < 2 else 1 << fx.F
        th = hw - (hw >> 11)
        t = (th * th) >> (2 * fx.F - 2 * fx.OPF)
        r = int(np.sqrt(t))
        ops = [(r - 1, 0), (r, 0), (r + 1, 0), (0, r + 1), (-r - 1, 0), (0, -r - 1), (0, 0), (131071, 131071),
               (-131072, -131072), (-131072, 131071)]
        ops += [((1 << q // 2) + d, 0) for q in (28, 30, 32) for d in (-1, 0, 1)]
        ops += [(-131071, 0), (-131072, 0), (-131072, 1)]             # m2 = 2^34 needs the negative end
        wide = [(a << 14, b << 14) for a, b in ops] + [((r << 14) + 8191, 0), ((r << 14) + 8192, 0),
                                                         ((r + 1 << 14) - 8193, 0), ((r + 1 << 14) - 8192, 0)]
        wide += [(int(a), int(b)) for a, b in rng.integers(-2**31, 2**31, size=(40, 2))]
        for irr, iri in wide:
            ilr, ili, exc, m2 = fx.limit(irr, iri, imx, cnt)
            lim = int(imx_pu < 2 and m2 > t)
            out.append(" ".join([hx(hw, 32), str(int(imx_pu < 2)), hx(irr, 32), hx(iri, 32), str(lim),
                                 hx(exc, 33), hx(ilr, 32), hx(ili, 32)]))
    return out


OUT.mkdir(parents=True, exist_ok=True)
emit("limcases.txt", limiter_cases())
emit("rom_sin.hex", [hx(v, 18) for v in fx.SIN])
emit("rom_seed.hex", [hx(v, 18) for v in fx.SEED])
for name, kw in CASES.items():
    g, ki, kf, sc, meth, tab, s = setup(name, kw)
    for wname, k0 in windows(name, g, sc, ki, kf, meth, tab, s).items():
        write_window(name, wname, k0, ki, kf, sc, meth, tab, s)
        print(f"{name:11s} {wname:9s} steps {k0}..{k0 + STEPS}  graph = model at the end")
h = hashlib.md5()
for f in sorted(OUT.glob("*")):
    if f.suffix in (".txt", ".hex"):
        h.update(f.read_bytes().replace(b"\r\n", b"\n"))
print("hash of all vector files:", h.hexdigest()[:12])
if CHECK:
    print("files that differ:", DIFF or "none")
    if DIFF:
        raise SystemExit(1)
