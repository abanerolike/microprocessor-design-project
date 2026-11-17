"""Stage 2c-4: one 1 us step of gfm_fixed.run (HW = True, 40-bit phase) written as a graph of hardware
operations that also computes its integer values. Because each operation takes its inputs as values,
the dependency list is the computation itself, so a wrong real/imaginary link cannot hide in the table.

1. Run the graph from many model states and compare with gfm_fixed.run bit by bit (normal steps and the
   1024th step with the grid update and UFLS).
2. Record the largest value each operation produced and check it against the declared output width.
3. List-schedule the graph inside the 50 clocks of CLOCK_50.

Units: latency L and initiation interval II (a new operation can start every II clocks on one unit)
  A   one 18x18 multiplier, registered output                       L 1, II 1
  B   up to 36x18: two 18x18 multipliers + registered adder        L 2, II 1 (pipelined) or 2
  C   37x18: three 18x18 multipliers + registered adder             L 2, II 1
  ADD add / subtract / round / saturate / compare / mux             L 1, no limit
  ROM synchronous M4K read; SIN1, SIN2 read two neighbours a clock  L 1, II 1
"""
from pathlib import Path
import numpy as np
import pandas as pd
import gfm_fixed as fx
import gfm_model as m

OUT = Path(__file__).with_name("results")
LAT = dict(A=1, B=2, C=2, ADD=1, ROM=1)
UNITS = dict(A=4, B=4, C=1)                          # 4 + 2*4 + 3 = 15 multipliers
CLOCKS = 50
F, FX, OPF, PH, FB = fx.F, fx.FX, fx.OPF, fx.PH, fx.FB
MASK = (1 << PH) - 1
rs = fx.rs.py_func


def sat(v, w):
    lim = 1 << (w - 1)
    return min(max(v, -lim), lim - 1)


def op(v):                                           # Q(32,28) -> Q(18,14) operand
    return sat(rs(v, F - OPF), 18)


class Sig:
    def __init__(self, name, v):
        self.name, self.v = name, v


class Graph:
    def __init__(self):
        self.ops, self.peak, self.last = {}, {}, {}

    def __call__(self, name, cls, f, *ins, w=0, note="", unit=None):
        v = f(*[s.v for s in ins])
        self.last[name] = v
        if name not in self.ops:
            self.ops[name] = dict(op=name, cls=cls, unit=unit or cls, out_bits=w, note=note,
                                  deps=[s.name for s in ins if not s.name.startswith("@")])
        if w:                                        # bits a signed value needs, tuples checked element-wise
            for x in (v if isinstance(v, tuple) else (v,)):
                self.peak[name] = max(self.peak.get(name, 0), int(x).bit_length() + 1)
        return Sig(name, v)


def step(G, s, aux, ki, kf, sc, meth, tab):
    """One step, same order and arithmetic as gfm_fixed.run. s: 23 state words, aux: step number, power sum,
    shed, UFLS tick counters and armed flags (gfm_fixed.aux0). Returns the new s and aux."""
    k, psum, shed = int(aux[0]), int(aux[1]), int(aux[2])
    nu = tab.shape[0]
    ticks, armed = [int(v) for v in aux[3:3 + nu]], [int(v) for v in aux[3 + nu:]]
    tick = (k + 1) % 1024 == 0
    S = {n: Sig("@" + n, int(v)) for n, v in zip(
        ["i1r", "i1i", "vcr", "vci", "i2r", "i2i", "i1fr", "i1fi", "vcfr", "vcfi", "i2fr", "i2fi",
         "uvr", "uvi", "uir", "uii", "pf", "qf", "th", "thg", "x", "pm", "dth"], s)}
    p0, trip, cap, imx0, imxc, ktrip, kshort, pg0 = (int(v) for v in sc)
    mc = lambda v, j: rs(v * int(ki[j]), int(kf[j]))
    imx = imx0 if k < kshort else imxc

    # sin and cos with linear interpolation, one ROM copy per angle
    trig = {}
    for ang, rom in (("th", "SIN1"), ("thg", "SIN2")):
        for part, off in (("s", 0), ("c", 256)):
            n = f"{ang}_{part}"
            r = G(f"{n}_rom", "ROM", lambda p, o=off: (int(fx.SIN[((p >> 30) + o) & 1023]),
                                                       int(fx.SIN[((p >> 30) + o + 1) & 1023])),
                  S[ang], w=18, unit=rom, note="u40 phase, address [39:30] (+256 for cos), next address wraps")
            d = G(f"{n}_d", "ADD", lambda r: r[1] - r[0], r, w=10, note="neighbour difference")
            mm = G(f"{n}_m", "A", lambda d, p: d * ((p >> (PH - 10 - FB)) & ((1 << FB) - 1)), d, S[ang], w=27,
                   note="x u16 fraction [29:14]")
            trig[n] = G(n, "ADD", lambda r, mm: r[0] + rs(mm, FB), r, mm, w=18, note="Q(18,16)")
    c, sn, cg, sg = trig["th_c"], trig["th_s"], trig["thg_c"], trig["thg_s"]

    # 1. control
    dpf = G("dpf", "ADD", lambda pf: p0 - pf, S["pf"], w=33)
    wm1 = G("wm1", "B", lambda d: mc(d, 10), dpf, w=27, note="dp (p0 - pf), F28")
    wop = G("wop", "ADD", lambda w: sat(rs((1 << F) + w, F - 16), 18), wm1, w=18, note="w at Q(18,16)")
    vq = G("vref_m", "B", lambda q: mc(q, 11), S["qf"], w=28)
    vrr = G("vref", "ADD", lambda q: (1 << F) - q, vq, w=33)
    evr = G("ev_r", "ADD", lambda v, c_: v - c_, vrr, S["vcfr"], w=34)
    ipr = G("ip_r", "B", lambda e: mc(e, 8), evr, w=36)
    ipi = G("ip_i", "B", lambda v: mc(-v, 8), S["vcfi"], w=36)
    wvr = G("wv_r", "A", lambda w, v: rs(w * op(v), fx.S1), wop, S["vcfr"], w=34, note="Q(18,16) x Q(18,14)")
    wvi = G("wv_i", "A", lambda w, v: rs(w * op(v), fx.S1), wop, S["vcfi"], w=34)
    fmi = G("ff_i", "B", lambda v: mc(v, 12), wvi, w=32, note="bC w vcf_i, enters the real part with -")
    fmr = G("ff_r", "B", lambda v: mc(v, 12), wvr, w=32, note="bC w vcf_r, enters the imaginary part with +")
    irr = G("ir_r", "ADD", lambda ip, fm, uv, i2f: sat(ip + uv - fm + i2f, 32), ipr, fmi, S["uvr"], S["i2fr"], w=32)
    iri = G("ir_i", "ADD", lambda ip, fm, uv, i2f: sat(ip + uv + fm + i2f, 32), ipi, fmr, S["uvi"], S["i2fi"], w=32)

    # limiter: always computed (fixed schedule); a flag selects the outputs, and m2 is held at 1/4 or more
    # so the normalizer and the seed ROM never see an input outside their range
    ior = G("io_r", "ADD", op, irr, w=18)
    ioi = G("io_i", "ADD", op, iri, w=18)
    sqr = G("sq_r", "A", lambda o: o * o, ior, w=37)
    sqi = G("sq_i", "A", lambda o: o * o, ioi, w=37)
    # the hardware limit range is Imax < 2 pu, which keeps the scale in 18 bits; Imax of 2 pu or more is the
    # "no limit" comparison mode: the flag stays 0 and the unused limiter path runs with Imax = 1 pu
    nolim = imx >= 2 << F
    imx_hw = 1 << F if nolim else imx
    thr = imx_hw - (imx_hw >> 11)
    m2 = G("m2", "ADD", lambda a, b: a + b, sqr, sqi, w=38, note="u37 F28")
    flag = G("lim", "ADD", lambda m: int(not nolim and m > (thr * thr) >> (2 * F - 2 * OPF)), m2, w=2,
             note="limited flag (0 in no-limit mode)")

    def norm(mv):
        mv = max(mv, 1 << 26)
        e = -1
        while mv >= 1 << (30 + 2 * e):
            e += 1
        return mv, e, mv >> (11 + 2 * e)
    nm = G("norm", "ADD", norm, m2, w=38, note="priority encoder: m2s = max(m2, 2^26), e in -1..3, u u19 Q17")
    y0 = G("seed", "ROM", lambda t: int(fx.SEED[(t[2] >> 11) - 64]), nm, w=18, unit="SEED")
    y2 = G("y2", "A", lambda y: rs(y * y, 17), y0, w=19)
    t_ = G("uy2", "B", lambda t, y: rs(t[2] * y, 17), nm, y2, w=20)
    z = G("z", "ADD", lambda t: (3 << 17) - t, t_, w=20)
    y1 = G("y1", "B", lambda y, z: (y * z) >> 18, y0, z, w=19)

    def scale(y, t):
        e = t[1]
        v = ((imx_hw * y) >> (F + 1)) - fx.MARGIN
        return min(v, 1 << (16 + e)) if e <= 0 else v
    scl = G("scl", "B", scale, y1, nm, w=19, note="Imax u29 F28 (< 2 pu) x u18 -> Q16 u18; - MARGIN; cap 2^(16+e)")
    mag = G("mag", "C", lambda t, y: (t[0] * y) >> (17 + t[1]), nm, y1, w=33, note="|i_raw| F28")
    exc = G("exc", "ADD", lambda mg, fl: max(mg - imx_hw, 0) if fl else 0, mag, flag, w=33, note="0 when not limited")
    ilr = G("il_r", "B", lambda i, s_, t, fl: rs(i * s_, 16 + t[1]) if fl else i, irr, scl, nm, flag, w=32,
            note="mux: limited ? scaled : i_raw")
    ili = G("il_i", "B", lambda i, s_, t, fl: rs(i * s_, 16 + t[1]) if fl else i, iri, scl, nm, flag, w=32)
    dmk = G("dmk", "B", lambda x_: mc(x_, 17) if meth == 1 else 0, exc, w=31, note="ks exc (fb only)")
    dm = G("dm", "ADD", lambda w, d: sat(rs(w - d, F - 20), 18), wm1, dmk, w=18, note="Q(18,20)")
    wir = G("wi_r", "A", lambda w, v: rs(w * op(v), fx.S1), wop, S["i1fr"], w=34)
    wii = G("wi_i", "A", lambda w, v: rs(w * op(v), fx.S1), wop, S["i1fi"], w=34)
    xwi = G("xw_i", "B", lambda v: mc(v, 13), wii, w=31, note="xL1 w i1f_i, into the real part with -")
    xwr = G("xw_r", "B", lambda v: mc(v, 13), wir, w=31, note="xL1 w i1f_r, into the imaginary part with +")
    der = G("de_r", "ADD", lambda a, b: a - b, ilr, S["i1fr"], w=33)
    dei = G("de_i", "ADD", lambda a, b: a - b, ili, S["i1fi"], w=33)
    kpr = G("kp_r", "B", lambda d: mc(d, 9), der, w=31)
    kpi = G("kp_i", "B", lambda d: mc(d, 9), dei, w=31)
    v1cr = G("v1c_r", "ADD", lambda v, kp, ui, xw: sat(rs(v + kp + ui - xw, F - 16), 18),
             S["vcfr"], kpr, S["uir"], xwi, w=18, note="Q(18,16)")
    v1ci = G("v1c_i", "ADD", lambda v, kp, ui, xw: sat(rs(v + kp + ui + xw, F - 16), 18),
             S["vcfi"], kpi, S["uii"], xwr, w=18)
    pr = {t: G(f"v1_{t}", "A", lambda a, b: a * b, x_, y_, w=36)
          for t, x_, y_ in (("ac", v1cr, c), ("bs", v1ci, sn), ("as", v1cr, sn), ("bc", v1ci, c))}
    v1r = G("v1_r", "ADD", lambda a, b: rs(a - b, 4), pr["ac"], pr["bs"], w=34)
    v1i = G("v1_i", "ADD", lambda a, b: rs(a + b, 4), pr["as"], pr["bc"], w=34)
    pgc = G("pg_c", "A", lambda c_, i: c_ * op(i), cg, S["i2r"], w=36)
    pgs = G("pg_s", "A", lambda s_, i: s_ * op(i), sg, S["i2i"], w=36)
    pg = G("pg", "ADD", lambda a, b: sat(rs(a + b, OPF + 2), 18), pgc, pgs, w=18, note="grid power sample Q(18,14)")

    # 2. LCL, semi-implicit; products of step-k states start at clock 0
    pk = {f"{nm_}_{p}": G(f"{nm_}_{p}", "B", lambda v, j=j: mc(v, j), S[f"{st}{p}"], w=w_)
          for nm_, st, j, w_ in (("r1i1", "i1", 14, 25), ("xl1i1", "i1", 13, 29), ("bcvc", "vc", 12, 32),
                                 ("r2i2", "i2", 16, 29), ("xl2i2", "i2", 15, 31)) for p in "ri"}
    s1r = G("s1_r", "ADD", lambda v1, vc, r, x_: v1 - vc - r + x_, v1r, S["vcr"], pk["r1i1_r"], pk["xl1i1_i"], w=35)
    s1i = G("s1_i", "ADD", lambda v1, vc, r, x_: v1 - vc - r - x_, v1i, S["vci"], pk["r1i1_i"], pk["xl1i1_r"], w=35)
    n1r = G("n1_r", "ADD", lambda i, a: sat(i + a, 32), S["i1r"], G("a1_r", "B", lambda v: mc(v, 5), s1r, w=28), w=32)
    n1i = G("n1_i", "ADD", lambda i, a: sat(i + a, 32), S["i1i"], G("a1_i", "B", lambda v: mc(v, 5), s1i, w=28), w=32)
    s2r = G("s2_r", "ADD", lambda n, i2, b: n - i2 + b, n1r, S["i2r"], pk["bcvc_i"], w=34)
    s2i = G("s2_i", "ADD", lambda n, i2, b: n - i2 - b, n1i, S["i2i"], pk["bcvc_r"], w=34)
    ncr = G("nc_r", "ADD", lambda v, a: sat(v + a, 32), S["vcr"], G("ac_r", "B", lambda v: mc(v, 6), s2r, w=26), w=32)
    nci = G("nc_i", "ADD", lambda v, a: sat(v + a, 32), S["vci"], G("ac_i", "B", lambda v: mc(v, 6), s2i, w=26), w=32)
    s3r = G("s3_r", "ADD", lambda n, g, r, x_: n - (g << (F - 16)) - r + x_, ncr, cg, pk["r2i2_r"], pk["xl2i2_i"], w=35)
    s3i = G("s3_i", "ADD", lambda n, g, r, x_: n - (g << (F - 16)) - r - x_, nci, sg, pk["r2i2_i"], pk["xl2i2_r"], w=35)
    n2r = G("n2_r", "ADD", lambda i, a: sat(i + a, 32), S["i2r"], G("a2_r", "B", lambda v: mc(v, 7), s3r, w=26), w=32)
    n2i = G("n2_i", "ADD", lambda i, a: sat(i + a, 32), S["i2i"], G("a2_i", "B", lambda v: mc(v, 7), s3i, w=26), w=32)

    # 3. integrators and the inverter angle
    new = {}
    for p, ev, il, ir, de in (("r", evr, ilr, irr, der), ("i", None, ili, iri, dei)):
        u1 = G(f"uv1_{p}", "B", lambda e: mc(e, 3), ev, w=24) if ev else G("uv1_i", "B", lambda v: mc(-v, 3), S["vcfi"], w=24)
        ad = G(f"aw_d_{p}", "ADD", lambda a, b: a - b, il, ir, w=33)
        aw = G(f"aw_{p}", "B", lambda d: mc(d, 4), ad, w=19)
        new[f"uv{p}"] = G(f"uv_{p}", "ADD", lambda u, a, b: sat(u + a + b, 32), S[f"uv{p}"], u1, aw, w=32)
        ui1 = G(f"ui1_{p}", "B", lambda d: mc(d, 2), de, w=17)
        new[f"ui{p}"] = G(f"ui_{p}", "ADD", lambda u, a: sat(u + a, 32), S[f"ui{p}"], ui1, w=32)
    inc = G("inc", "A", lambda d: rs(d * fx.KPH, 20 + fx.KPF), dm, w=26, note="phase step s25")
    new["th"] = G("th", "ADD", lambda t, i: (t + i) & MASK, S["th"], inc, w=42, note="u40, wraps")

    # 4. filters on step-k measurements (rot = c - j sn)
    for X in ("i1", "vc", "i2"):
        a_, b_ = S[f"{X}r"], S[f"{X}i"]
        r4 = {t: G(f"{X}rot_{t}", "A", lambda x_, y_: op(x_) * y_, u_, v_, w=36)
              for t, u_, v_ in (("ac", a_, c), ("bs", b_, sn), ("bc", b_, c), ("as", a_, sn))}
        rr = G(f"{X}rot_r", "ADD", lambda p_, q_: sat(rs(p_ + q_, fx.S1), 32), r4["ac"], r4["bs"], w=32)
        ri = G(f"{X}rot_i", "ADD", lambda p_, q_: sat(rs(p_ - q_, fx.S1), 32), r4["bc"], r4["as"], w=32)
        for p, rot in (("r", rr), ("i", ri)):
            d = G(f"{X}f_d_{p}", "ADD", lambda a, b: a - b, rot, S[f"{X}f{p}"], w=33)
            new[f"{X}f{p}"] = G(f"{X}f_{p}", "ADD", lambda f_, mm: sat(f_ + mm, 32), S[f"{X}f{p}"],
                                G(f"{X}f_m_{p}", "B", lambda v: mc(v, 0), d, w=25), w=32)
    sp = {t: G(f"sp_{t}", "A", lambda a, b: op(a) * op(b), S[u_], S[v_], w=36)
          for t, u_, v_ in (("rr", "vcfr", "i2fr"), ("ii", "vcfi", "i2fi"), ("ir", "vcfi", "i2fr"), ("ri", "vcfr", "i2fi"))}
    spr = G("sp_r", "ADD", lambda a, b: sat(a + b, 32), sp["rr"], sp["ii"], w=32)
    spi = G("sp_i", "ADD", lambda a, b: sat(a - b, 32), sp["ir"], sp["ri"], w=32)
    for nme, s_ in (("pf", spr), ("qf", spi)):
        d = G(f"{nme}_d", "ADD", lambda a, b: a - b, s_, S[nme], w=33)
        new[nme] = G(nme, "ADD", lambda f_, mm: sat(f_ + mm, 32), S[nme], G(f"{nme}_m", "B", lambda v: mc(v, 1), d, w=19), w=32)

    # 5. grid: angle every step with the frequency held from the last update
    incg = G("incg", "A", lambda x_: rs(sat(rs(x_, FX - 21), 18) * fx.KPH, 21 + fx.KPF), S["x"], w=25)
    new["thg"] = G("thg", "ADD", lambda t, i: (t + i) & MASK, S["thg"], incg, w=42)
    ps = G("psum", "ADD", lambda a: sat(psum + a, 28), pg, w=28)
    x_new, pm_new = S["x"], S["pm"]
    if tick:                                         # 1024th step: this step's sample is in psum already
        tr = trip if k >= ktrip else 0
        dpg = G("dpg", "ADD", lambda a: rs(a, 10) - pg0, ps, w=20)
        rdp = G("rdp", "B", lambda d: rs(d * int(ki[22]), int(kf[22]) + 14 - FX), dpg, w=30)
        dxk = G("dxk", "B", lambda x_: mc(x_, 21), S["x"], w=33)
        dx = G("dx", "ADD", lambda pm, d, r: pm - tr - d + r + shed, S["pm"], dxk, rdp, w=35)
        x_new = G("x", "ADD", lambda x_, mm: sat(x_ + mm, 32), S["x"], G("x_m", "B", lambda v: mc(v, 18), dx, w=24), w=32)
        pmk = G("pmk", "B", lambda x_: mc(x_, 20), S["x"], w=35)
        dpm = G("dpm", "ADD", lambda k_, pm: -k_ - pm, pmk, S["pm"], w=36)
        pmm = G("pm_m", "B", lambda v: mc(v, 19), dpm, w=25)
        pm_new = G("pm", "ADD", lambda pm, d, mm: pm if (pm >= cap and d > 0) else sat(pm + mm, 32), S["pm"], dpm, pmm,
                   w=32, note="held at the reserve cap when rising")

        def ufls(xn):                                # uses the new x, like the model
            sh = shed
            for j in range(tab.shape[0]):
                if armed[j]:
                    ticks[j] = ticks[j] + 1 if xn < tab[j, 0] else 0
                    if ticks[j] >= tab[j, 1]:
                        sh += int(tab[j, 2])
                        armed[j] = 0
            return sh
        shed = G("ufls", "ADD", ufls, x_new, w=32, note="7 compares, tick counters, shed").v
        ps = Sig("psum", 0)
    out = [n1r, n1i, ncr, nci, n2r, n2i, new["i1fr"], new["i1fi"], new["vcfr"], new["vcfi"], new["i2fr"], new["i2fi"],
           new["uvr"], new["uvi"], new["uir"], new["uii"], new["pf"], new["qf"], new["th"], new["thg"], x_new, pm_new]
    return [o.v for o in out] + [S["dth"].v + inc.v - incg.v], [k + 1, ps.v, shed] + ticks + armed


def bit_check():
    """Graph against gfm_fixed.run from many states of three cases. Returns a table of mismatches."""
    G, rows = Graph(), []
    tab = fx.ufls_table()
    B = dict(H=3.3, D=2.0, K=0.3, Tg=3.0, trip=3.3 / 80, cap=1.0 / 80, r=0.10, p0=0.9)
    for name, kw in {"held, fb": B | dict(imax_cont=1.2, method="fb", ks=0.2), "held, sat": B | dict(imax_cont=1.2),
                     "spec, fb": B | dict(method="fb", ks=0.2),
                     "no limit": B | dict(imax=10.0, imax_cont=10.0, method="fb", ks=0.2)}.items():
        g = m.GRID | kw
        ki, kf = fx.consts(g)
        meth = 1 if g["method"] == "fb" else 0
        s = fx.to_int(m.unpack(m.settle(g)[0]))
        cap = round(g["cap"] * 2**FX)
        imx0, imxc = round(g["imax"] * 2**F), round(g["imax_cont"] * 2**F)
        p0 = round(g["p0"] * 2**F)
        s, _, _, pg0, _ = fx.run(s, ki, kf, np.array([p0, 0, cap, imx0, imx0, 1 << 40, 1 << 40, 0]), 1_000_000,
                                 0, False, False, 1_000_000, tab, fx.aux0())
        for j in range(16):                          # states every 0.2 s after a trip at the start
            short = 0 if (name == "spec, fb" and j >= 8) else 1 << 40
            sc = np.array([p0, round(g["trip"] * 2**FX), cap, imx0, imxc, 0, short, pg0], dtype=np.int64)
            # a normal step, 1024 steps ending with the grid update, and once 200 updates where UFLS trips
            for n in (1, 1024) + ((200 * 1024,) if (name, j) == ("held, sat", 8) else ()):
                ref, _, _, _, ref_aux = fx.run(s.copy(), ki, kf, sc, n, meth, True, True, 1, tab, fx.aux0())
                st_, aux = list(s), list(fx.aux0())
                for _ in range(n):
                    st_, aux = step(G, st_, aux, ki, kf, sc, meth, tab)
                bad = int(np.sum(np.array(st_ + aux, dtype=np.int64) != np.concatenate((ref, ref_aux))))
                rows.append([name, round(0.2 * j, 1), n, bad])
            s = fx.run(s, ki, kf, sc, 200_000, meth, True, True, 200_000, tab, fx.aux0())[0]
    return G, pd.DataFrame(rows, columns=["Case", "t after trip [s]", "steps", "words that differ (23 state + 17 aux)"])


def schedule(ops, ii_b):
    tail, done, busy, ii = {}, {}, {}, dict(A=1, B=ii_b, C=1)
    users = {n: [o for o in ops.values() if n in o["deps"]] for n in ops}

    def path(n):
        if n not in tail:
            tail[n] = LAT[ops[n]["cls"]] + max([path(u["op"]) for u in users[n]], default=0)
        return tail[n]

    left, t = sorted(ops.values(), key=lambda o: -path(o["op"])), 0
    while left:
        for o in list(left):
            if any(d not in done for d in o["deps"]) or max([done[d] for d in o["deps"]], default=0) > t:
                continue
            u, cap = o["unit"], UNITS.get(o["unit"], 1 if o["cls"] == "ROM" else None)
            if cap is not None and busy.get((t, u), 0) >= cap:
                continue
            for dt in range(ii.get(o["cls"], 1)):    # a unit stays busy for its initiation interval
                busy[(t + dt, u)] = busy.get((t + dt, u), 0) + 1
            o.update(ready=max([done[d] for d in o["deps"]], default=0), start=t, done=t + LAT[o["cls"]])
            done[o["op"]] = o["done"]
            left.remove(o)
        t += 1
    return max(done.values()), path


if __name__ == "__main__":
    G, chk = bit_check()
    print(chk.groupby(["Case", "steps"])[chk.columns[-1]].agg(["count", "sum"]).to_string())
    for o in G.ops.values():
        o["peak bits"] = G.peak.get(o["op"], 0)
    over = [o["op"] for o in G.ops.values() if o["peak bits"] > o["out_bits"]]
    print("operations whose largest value needs more bits than declared:", over or "none")
    big = 0                                              # scale over every seed bucket for Imax up to just below 2 pu
    for e in range(-1, 4):
        for u in range(1 << 17, 1 << 19):
            y, ee = fx.invsqrt.py_func(u << (11 + 2 * e))
            v = ((((2 << F) - 1) * y) >> (F + 1)) - fx.MARGIN
            big = max(big, min(v, 1 << (16 + ee)) if ee <= 0 else v)
    print(f"largest scale for any Imax below 2 pu: {big} -> fits the 18-bit unsigned port: {big < 1 << 18}")
    print("UFLS shed during the check:", G.peak.get("ufls", 0) > 1, "| limiter active during the check:", G.peak["lim"] > 1)

    last1, path = schedule({k: dict(v) for k, v in G.ops.items()}, 2)
    print(f"B units with initiation interval 2 clocks: all results valid by clock {last1}")
    last, path = schedule(G.ops, 1)
    tab = pd.DataFrame(G.ops.values())
    tab["deps"] = tab["deps"].map(" ".join)
    tab["used by"] = [" ".join(u["op"] for u in G.ops.values() if o["op"] in u["deps"]) for o in G.ops.values()]
    tab = tab.sort_values(["start", "op"])[["op", "cls", "unit", "deps", "ready", "start", "done", "used by",
                                            "out_bits", "peak bits", "note"]]
    tab.to_csv(OUT / "stage2c4_schedule.csv", index=False)
    chk.to_csv(OUT / "stage2c4_bitcheck.csv", index=False)
    print(f"operations {len(tab)}: " + ", ".join(f"{c} {n}" for c, n in tab.cls.value_counts().items()))
    print(f"B units pipelined (interval 1): all results valid by clock {last} of {CLOCKS} -> "
          f"{'fits' if last < CLOCKS else 'DOES NOT FIT'}; multipliers {UNITS['A'] + 2 * UNITS['B'] + 3 * UNITS['C']}")
    crit = []
    for n in tab.op[tab.start + tab.op.map(path) == last]:
        n = n[:-2] if n[-2:] in ("_r", "_i") else n
        if n not in crit:
            crit.append(n)
    print("critical chain:", " -> ".join(crit))
