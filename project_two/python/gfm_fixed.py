"""Stage 2c: the 2b model (grid every 1024 steps, delay 0) in integer arithmetic.

Formats (W total bits, F fraction bits):
  device states and wide signals  Q(32,28)    grid x, Pm, shed   Q(32,31)
  multiplier operands             Q(18,14)    sin, cos, converter voltage  Q(18,16)
  w - 1 and wth - 1               Q(18,20)    phase              PH-bit unsigned, wraps (40)
  |i_raw|^2                       Q(37,28)    1024-sample power sum  28 bits of Q(18,14)
  constants                       18 bits each, own F
Every product is formed at full width, rounded half up (add half, arithmetic shift),
then range-checked; a value outside its format is saturated and counted.
State update paths (difference -> constant -> sum) stay wide; only signal x signal
products use 18-bit operands.
HW = False (2c-1): sin/cos and 1/sqrt from floating point, rounded to their formats.
HW = True  (2c-2): sin/cos from a 1024-point ROM with linear interpolation,
1/sqrt from a 192-point ROM seed and one Newton step, all in integers.
Stage 5c (pv = 1: vdc 2.4 pu, pv = 2: 4.0 pu; pv = 0 is the average model above): three-phase PWM in
20 ns ticks, 50 per step. Nominal angle phi_k = k * f0 * 1 us (the PH-bit phase step), carrier 0..6250..1
(4 kHz), compare D > carrier, dead time 100 ticks (a switch turns on 100 ticks after its command, off at
once; meanwhile the leg follows the phase current: negative -> +vdc/2, else -vdc/2). Order, as in hardware:
  the duty pending for step k+1 is made from v1(k) at phi_{k+1}; the active duty takes it only at the
    carrier ends (k mod 125 = 0), so a v1 ready later waits for the next end
  the current signs used in step k come from i1(k) at phi_k
  u(k), the mean phase voltage of step k (from the 3 counts of high ticks), drives the LCL in step k+1
Start (aux init flag): the pending and active duty are made from v1 of the first step at its angle, the
gates match the first compare with the dead time over, and the LCL takes that v1 in the first step.
"""
import numpy as np
from numba import njit
import gfm_model as m
import gfm_discrete as q

TS = 1e-6
F, FX, PH = 28, 31, 40
OPF, OPW = 14, 18                  # device operand Q(OPW, OPF)
S1 = OPF + 16 - F                  # operand x sin/cos (or x w) back to F
HW = True
FB = 16                            # interpolation fraction bits
SIN = np.round(np.sin(2 * np.pi * np.arange(1024) / 1024) * 2**16).astype(np.int64)
NH, ND, TPS = 6250, 100, 50       # PWM: carrier half period, dead time, ticks per step
VDC = np.array([0, 2.4, 4.0])      # pv 1, 2
VK = np.round(np.r_[0, NH / VDC[1:]] * 2**5).astype(np.int64)                  # NH / vdc, F = 5
U1 = np.round(VDC / 150 * 2**21).astype(np.int64)                             # vdc / 150, F = 21
U2 = np.round(np.sqrt(3) * VDC / 150 * 2**21).astype(np.int64)                # sqrt(3) vdc / 150
H3 = 113512                        # sqrt(3) / 2 at F = 17
# seed for 1/sqrt(u), u in [1, 4) in 192 steps of 1/64, taken at the top of each step so it never overshoots
SEED = np.floor(2**17 / np.sqrt((np.arange(192) + 65) / 64)).astype(np.int64)
MARGIN = 4                         # scale LSBs taken off so the limited reference never exceeds Imax
NAMES = ["af1", "af2", "tkii", "tkiv", "taw", "a1", "ac", "a2", "kpv", "kpi", "dp", "dq",
         "bc", "xl1", "r1", "xl2t", "r2t", "ks", "gh", "gt", "kr", "dd", "rr"]


def const18(c):
    """Largest F that keeps c in an 18-bit signed integer."""
    if c == 0:
        return 0, 0
    f = 17 - int(np.floor(np.log2(abs(c)))) - 1
    while abs(round(c * 2.0**f)) >= 2**17:
        f -= 1
    return round(c * 2.0**f), f


def set_phase_bits(ph):
    """Phase accumulator width. Call before the first run (Numba freezes the globals at compile time)."""
    global PH, KPH, KPF
    PH = ph
    KPH, KPF = const18(m.F0 * TS * 2.0**ph)                  # phase step per unit speed per microsecond


set_phase_bits(40)


def consts(g):
    d = m.DEV
    real = dict(af1=1 - np.exp(-d["wc1"] * TS), af2=1 - np.exp(-d["wc2"] * TS), tkii=TS * d["kii"],
                tkiv=TS * d["kiv"], taw=TS * d["kiv"] / d["kpv"], a1=TS * m.WB / d["xl1"],
                ac=TS * m.WB / d["bc"], a2=TS * m.WB / (d["xl2"] + g["xg"]), kpv=d["kpv"], kpi=d["kpi"],
                dp=d["dp"], dq=d["dq"], bc=d["bc"], xl1=d["xl1"], r1=d["r1"], xl2t=d["xl2"] + g["xg"],
                r2t=d["r2"] + g["rg"], ks=g["ks"], gh=1024 * TS / (2 * g["H"]),
                gt=1024 * TS / g["Tg"], kr=g["K"] / g["R"], dd=g["D"], rr=g["r"])
    ki, kf = zip(*(const18(real[n]) for n in NAMES))
    return np.array(ki, dtype=np.int64), np.array(kf, dtype=np.int64)


@njit
def rs(v, n):
    return (v + (1 << (n - 1))) >> n if n > 0 else v << -n


@njit
def sat(v, w, cnt):
    lim = 1 << (w - 1)
    if v >= lim or v < -lim:
        cnt[0] += 1
        return lim - 1 if v > 0 else -lim
    return v


@njit
def trig(ph):
    if not HW:
        a = ph * (2 * np.pi / 2.0**PH)
        return int(np.round(np.cos(a) * 2.0**16)), int(np.round(np.sin(a) * 2.0**16))
    adr = ph >> (PH - 10)
    fr = (ph >> (PH - 10 - FB)) & ((1 << FB) - 1)
    s0, s1 = SIN[adr], SIN[(adr + 1) & 1023]
    c0, c1 = SIN[(adr + 256) & 1023], SIN[(adr + 257) & 1023]
    return c0 + rs((c1 - c0) * fr, FB), s0 + rs((s1 - s0) * fr, FB)


@njit
def invsqrt(m2):
    """1/sqrt(m2) for m2 at F = 28 and >= 1/4: returns y at Q17 and e, with 1/sqrt(m2) = y / 2^e."""
    e = -1
    while m2 >= 1 << (30 + 2 * e):                   # priority encoder in hardware
        e += 1
    u = m2 >> (11 + 2 * e)                           # Q17, in [1, 4)
    y0 = SEED[(u >> 11) - 64]
    t = rs(u * rs(y0 * y0, 17), 17)
    return (y0 * ((3 << 17) - t)) >> 18, e


@njit
def limit(irr, iri, imx, cnt):
    """Current reference limiter. Returns the reference, |i_raw| - imx (F = 28, not below 0) and |i_raw|^2.
    The decision and the scale use the rounded operands, and the wide vector can be up to 0.71 operand
    LSB longer. So the reference passes through unchanged only when it is at least one operand LSB
    inside imx, and the scale is applied to the wide vector with MARGIN covering that 0.71 LSB."""
    orr, ori = sat(rs(irr, F - OPF), OPW, cnt), sat(rs(iri, F - OPF), OPW, cnt)
    m2 = orr * orr + ori * ori                                    # F = 2 OPF
    th = imx - (imx >> 11)
    if imx >= 2 << F or m2 <= (th * th) >> (2 * F - 2 * OPF):    # Imax of 2 pu or more: "no limit" mode
        return irr, iri, 0, m2
    if HW:
        y, e = invsqrt(m2)
        scl = ((imx * y) >> (F + 1)) - MARGIN                    # Imax y at Q16; the exponent goes in the shift
        exc = max(((m2 * y) >> (17 + e)) - imx, 0)
    else:
        mag = np.sqrt(m2 / 2.0**(2 * OPF))
        e = 0
        scl = int(imx / 2.0**F / mag * 2.0**16)
        exc = max(int(np.round((mag - imx / 2.0**F) * 2.0**F)), 0)
    if e <= 0:
        scl = min(scl, 1 << (16 + e))                             # scale 1 at most: passes the wide vector as is
    return rs(irr * scl, 16 + e), rs(iri * scl, 16 + e), exc, m2   # scale the wide vector, not the operand


@njit
def duty(vr, vi, ph, pv, cnt):
    """Compare values (ticks) of the three legs for v1 (Q28) at angle ph, clipped to 0..NH; also clipped or not."""
    a, b = sat(rs(vr, F - 16), 18, cnt), sat(rs(vi, F - 16), 18, cnt)
    c, sn = trig(ph)
    wr, wi = rs(a * c - b * sn, 16), rs(a * sn + b * c, 16)
    h, hw = rs(wi * H3, 17), rs(wr, 1)
    d = np.zeros(3, dtype=np.int64)
    clip = False
    for x, p in enumerate((wr, h - hw, -h - hw)):
        v = NH // 2 + ((p * VK[pv] + (1 << 21) - 1) >> 21)    # ceil: on while the exact duty is above the carrier
        clip = clip or v < 0 or v > NH
        d[x] = min(max(v, 0), NH)
    return d, clip


@njit
def back(n0, n1, n2, ph, pv):
    """Mean phase voltage of one step (Q28 frame value) from the high-tick counts, at angle ph."""
    gr, gi = rs((2 * n0 - n1 - n2) * U1[pv], 6), rs((n1 - n2) * U2[pv], 6)     # Q15
    c, sn = trig(ph)
    return rs(gr * c + gi * sn, 3), rs(gi * c - gr * sn, 3)


@njit
def neg(i1r, i1i, ph, cnt):
    """Phase currents below zero (a, b, c) for i1 at angle ph."""
    a, b = sat(rs(i1r, F - OPF), OPW, cnt), sat(rs(i1i, F - OPF), OPW, cnt)
    c, sn = trig(ph)
    r, i = rs(a * c - b * sn, 16), rs(a * sn + b * c, 16)
    t = i * H3 - (r << 16)
    return r < 0, t < 0, -i * H3 - (r << 16) < 0


@njit
def run(s, ki, kf, sc, n, meth, couple, ufls_on, rec_every, tab, aux, pv=0):
    (i1r, i1i, vcr, vci, i2r, i2i, i1fr, i1fi, vcfr, vcfi, i2fr, i2fi,
     uvr, uvi, uir, uii, pf, qf, th, thg, x, pm, dth) = s
    p0, trip, cap, imx0, imxc, ktrip, kshort, pg0 = sc
    cnt = np.zeros(1, dtype=np.int64)
    one = 1 << F

    def mc(v, j):                                      # constant j times v, result at v's scale
        return rs(v * ki[j], kf[j])

    def op(v):                                         # Q(32,28) -> device operand
        return sat(rs(v, F - OPF), OPW, cnt)

    def st(v):                                         # store into a 32-bit state
        return sat(v, 32, cnt)

    # aux: step number k0 of the first step, power sum, shed, UFLS tick counters, UFLS armed flags
    k0, psum, shed = aux[0], aux[1], aux[2]
    ticks, armed = aux[3:3 + tab.shape[0]].copy(), aux[3 + tab.shape[0]:3 + 2 * tab.shape[0]].copy()
    # PWM (pv > 0): init flag, active duty, pending duty, gate commands, dead-time counters, u for the LCL
    pw = aux[3 + 2 * tab.shape[0]:].copy() if pv > 0 else np.zeros(15, dtype=np.int64)
    dact, dpen, cmd, dct = pw[1:4], pw[4:7], pw[7:10], pw[10:13]
    nclip, pcl, acl = 0, False, False              # ticks with a clipped duty applied (not kept across runs)
    rec = np.zeros(((n + rec_every - 1) // rec_every, 8))
    fmin, i1max, t_over, energy, omax = 60.0, 0.0, 0.0, 0.0, 0.0
    pre = np.array([1e9, -1e9, 1e9, -1e9])             # f min, f max, |i1| min, |i1| max before the trip
    dmin, dmax = dth, dth

    for j in range(n):
        k = k0 + j
        # 1. control from step-k states
        c, sn = trig(th)                               # rot = c - j sn
        cg, sg = trig(thg)
        wm1 = mc(p0 - pf, 10)
        vrr = one - mc(qf, 11)
        ipr, ipi = mc(vrr - vcfr, 8), mc(-vcfi, 8)
        wop = sat(rs(one + wm1, F - 16), 18, cnt)
        wvr, wvi = rs(wop * op(vcfr), S1), rs(wop * op(vcfi), S1)
        ffr, ffi = -mc(wvi, 12) + i2fr, mc(wvr, 12) + i2fi
        irr, iri = st(ipr + uvr + ffr), st(ipi + uvi + ffi)      # Q(32,28): keeps the products after it at 32 bits
        imx = imx0 if k < kshort else imxc
        ilr, ili, exc, m2 = limit(irr, iri, imx, cnt)
        dm = sat(rs(wm1 - (mc(exc, 17) if meth == 1 else 0), F - 20), 18, cnt)
        wir, wii = rs(wop * op(i1fr), S1), rs(wop * op(i1fi), S1)
        vcr_ = vcfr + mc(ilr - i1fr, 9) + uir - mc(wii, 13)
        vci_ = vcfi + mc(ili - i1fi, 9) + uii + mc(wir, 13)
        a, b = sat(rs(vcr_, F - 16), 18, cnt), sat(rs(vci_, F - 16), 18, cnt)   # Q(18,16): Q(18,14) here limit-cycles
        v1r, v1i = rs(a * c - b * sn, 4), rs(a * sn + b * c, 4)
        pg = sat(rs(cg * op(i2r) + sg * op(i2i), OPF + 2), 18, cnt)
        ur, ui = v1r, v1i
        if pv > 0:
            kn = rs(KPH, KPF)                          # nominal phase step per 1 us
            phk = (k * kn) & ((1 << PH) - 1)
            if pw[0] == 1:                             # start: registers from this step's v1
                d, pcl = duty(v1r, v1i, phk, pv, cnt)
                q0 = TPS * k % (2 * NH)
                for g in range(3):
                    dpen[g], cmd[g], dct[g] = d[g], d[g] > min(q0, 2 * NH - q0), ND
                pw[13], pw[14], pw[0] = v1r, v1i, 0
            if k % (NH // TPS) == 0:                   # carrier end at the first tick of this step
                dact[:] = dpen
                acl = pcl
            ng = neg(i1r, i1i, phk, cnt)
            nh = np.zeros(3, dtype=np.int64)
            for t in range(TPS):
                qq = (TPS * k + t) % (2 * NH)
                cr = min(qq, 2 * NH - qq)
                for g in range(3):
                    cm = 1 if dact[g] > cr else 0
                    if cm != cmd[g]:
                        cmd[g], dct[g] = cm, 0
                    nh[g] += cm if dct[g] >= ND else ng[g]
                    dct[g] = min(dct[g] + 1, ND)
            nclip += TPS if acl else 0
            ur, ui = pw[13], pw[14]                    # u(k-1)
            d, pcl = duty(v1r, v1i, (phk + kn) & ((1 << PH) - 1), pv, cnt)
            dpen[:] = d
            pw[13], pw[14] = back(nh[0], nh[1], nh[2], phk, pv)

        # metrics and record row k
        f = 60.0 * (1 + x / 2.0**FX)
        ai = np.hypot(i1r, i1i) / 2.0**F
        imf = imx / 2.0**F
        if k < ktrip:
            pre[0], pre[1] = min(pre[0], f), max(pre[1], f)
            pre[2], pre[3] = min(pre[2], ai), max(pre[3], ai)
        else:
            fmin, i1max, omax = min(fmin, f), max(i1max, ai), max(omax, ai - imf)
            if ai - imf > 0.005 * imf:
                t_over += TS
            energy += TS * ki[22] / 2.0**kf[22] * (pg - pg0) / 2.0**14 * 80
            dmin, dmax = min(dmin, dth), max(dmax, dth)
        if j % rec_every == 0:
            rec[j // rec_every] = (k * TS, f, ai, np.sqrt(m2 / 2.0**(2 * OPF)), imf,
                                   ki[22] / 2.0**kf[22] * (pg - pg0) / 2.0**14 * 80,
                                   dth * 2 * np.pi / 2.0**PH, shed / 2.0**FX * 80)

        # 2. LCL, semi-implicit
        s1r = ur - vcr - mc(i1r, 14) + mc(i1i, 13)
        s1i = ui - vci - mc(i1i, 14) - mc(i1r, 13)
        n1r, n1i = st(i1r + mc(s1r, 5)), st(i1i + mc(s1i, 5))
        s2r, s2i = n1r - i2r + mc(vci, 12), n1i - i2i - mc(vcr, 12)
        ncr, nci = st(vcr + mc(s2r, 6)), st(vci + mc(s2i, 6))
        s3r = ncr - (cg << (F - 16)) - mc(i2r, 16) + mc(i2i, 15)
        s3i = nci - (sg << (F - 16)) - mc(i2i, 16) - mc(i2r, 15)
        n2r, n2i = st(i2r + mc(s3r, 7)), st(i2i + mc(s3i, 7))

        # 3. integrators and angle
        uvr = st(uvr + mc(vrr - vcfr, 3) + mc(ilr - irr, 4))
        uvi = st(uvi + mc(-vcfi, 3) + mc(ili - iri, 4))
        uir, uii = st(uir + mc(ilr - i1fr, 2)), st(uii + mc(ili - i1fi, 2))
        inc = rs(dm * KPH, 20 + KPF)                   # Q(18,20) speed x phase per unit speed
        th = (th + inc) & ((1 << PH) - 1)

        # 4. filters on step-k measurements (rot = c - j sn)
        sr = st(rs(op(vcfr) * op(i2fr) + op(vcfi) * op(i2fi), 2 * OPF - F))
        si = st(rs(op(vcfi) * op(i2fr) - op(vcfr) * op(i2fi), 2 * OPF - F))
        a, b = op(i1r), op(i1i)
        i1fr, i1fi = st(i1fr + mc(st(rs(a * c + b * sn, S1)) - i1fr, 0)), st(i1fi + mc(st(rs(b * c - a * sn, S1)) - i1fi, 0))
        a, b = op(vcr), op(vci)
        vcfr, vcfi = st(vcfr + mc(st(rs(a * c + b * sn, S1)) - vcfr, 0)), st(vcfi + mc(st(rs(b * c - a * sn, S1)) - vcfi, 0))
        a, b = op(i2r), op(i2i)
        i2fr, i2fi = st(i2fr + mc(st(rs(a * c + b * sn, S1)) - i2fr, 0)), st(i2fi + mc(st(rs(b * c - a * sn, S1)) - i2fi, 0))
        pf, qf = st(pf + mc(sr - pf, 1)), st(qf + mc(si - qf, 1))
        i1r, i1i, vcr, vci, i2r, i2i = n1r, n1i, ncr, nci, n2r, n2i

        # 5. grid: angle every step with the held frequency, the rest every 1024 steps
        if couple:
            incg = rs(sat(rs(x, FX - 21), 18, cnt) * KPH, 21 + KPF)
            thg = (thg + incg) & ((1 << PH) - 1)
            dth += inc - incg
            psum = sat(psum + pg, 28, cnt)
            if (k + 1) % 1024 == 0:
                tr = trip if k >= ktrip else 0
                dpg = rs(psum, 10) - pg0
                dx = pm - tr - mc(x, 21) + rs(dpg * ki[22], kf[22] + 14 - FX) + shed
                dpm = -mc(x, 20) - pm
                x = st(x + mc(dx, 18))
                if not (pm >= cap and dpm > 0):
                    pm = st(pm + mc(dpm, 19))
                psum = 0
        else:
            dth += inc

        # 6. UFLS on the 1.024 ms tick
        if ufls_on and (k + 1) % 1024 == 0:
            for u in range(tab.shape[0]):
                if armed[u] > 0:
                    ticks[u] = ticks[u] + 1 if x < tab[u, 0] else 0
                    if ticks[u] >= tab[u, 1]:
                        shed += tab[u, 2]
                        armed[u] = 0

    cg, sg = trig(thg)
    pg = sat(rs(cg * op(i2r) + sg * op(i2i), OPF + 2), 18, cnt)
    s_out = np.array([i1r, i1i, vcr, vci, i2r, i2i, i1fr, i1fi, vcfr, vcfi, i2fr, i2fi,
                      uvr, uvi, uir, uii, pf, qf, th, thg, x, pm, dth], dtype=np.int64)
    stats = np.array([fmin, i1max, t_over, energy, shed / 2.0**FX * 80, 60 * (1 + x / 2.0**FX),
                      (dmax - dmin) // 2**PH, omax, cnt[0], pre[1] - pre[0], pre[3] - pre[2], nclip * TS / TPS])
    aux_out = np.concatenate((np.array([k0 + n, psum, shed], dtype=np.int64), ticks, armed))
    if pv > 0:
        aux_out = np.concatenate((aux_out, pw))
    return s_out, rec, stats, pg, aux_out


def to_int(s):
    """Continuous settle result -> integer states."""
    out = []
    for nme in m.C_NAMES:
        out += [round(s[nme].real * 2**F), round(s[nme].imag * 2**F)]
    out += [round(s["pf"] * 2**F), round(s["qf"] * 2**F)]
    out += [round(s["th"] / (2 * np.pi) * 2**PH) % 2**PH, round(s["thg"] / (2 * np.pi) * 2**PH) % 2**PH]
    out += [round(s["x"] * 2**FX), round(s["pm"] * 2**FX), round((s["th"] - s["thg"]) / (2 * np.pi) * 2**PH)]
    return np.array(out, dtype=np.int64)


def aux0(pv=0):
    """Run-internal state at a fresh start: step 0, empty power sum, nothing shed, all UFLS stages armed;
    with PWM (pv > 0) the PWM registers, flagged to start from the first step's v1."""
    return np.array([0, 0, 0] + [0] * len(m.UFLS) + [1] * len(m.UFLS) + ([1] + [0] * 14 if pv else []),
                    dtype=np.int64)


def ufls_table():
    return np.array([[round((fs / 60 - 1) * 2**FX), int(np.ceil((dl - 1e-9) / 1.024e-3)), round(fr * 2**FX)]
                     for fs, dl, fr in m.UFLS], dtype=np.int64)


def simulate(t_end=20.0, rec_every=1024, pv=0, **kw):
    """Same common start as 2a/2b, then the trip run, all in integers. Only sat and fb. pv > 0: with PWM."""
    g = m.GRID | kw
    for v in (g["imax"], g["imax_cont"]):            # limiter checked only at these; 2 pu or more means no limit
        if not (v in (1.0, 1.2) or v >= 2.0):         # an explicit error: python -O drops asserts
            raise ValueError(f"Imax {v} pu: not verified for the integer limiter")
    y, _ = m.settle(g)
    s = to_int(m.unpack(y))
    ki, kf = consts(g)
    tab = ufls_table()
    big = 1 << 40
    cap = big if g["cap"] is None else round(g["cap"] * 2**FX)
    imx0, imxc = round(g["imax"] * 2**F), round(g["imax_cont"] * 2**F)
    p0 = round(g["p0"] * 2**F)
    sc = np.array([p0, 0, cap, imx0, imx0, big, big, 0], dtype=np.int64)
    s, _, _, pg0, _ = run(s, ki, kf, sc, 1_000_000, 0, False, False, 1_000_000, tab, aux0())
    kt = round(g["t_trip"] / TS)
    sc = np.array([p0, round(g["trip"] * 2**FX), cap, imx0, imxc, kt, kt + round(g["t_short"] / TS), pg0],
                  dtype=np.int64)
    s, rec, st, _, _ = run(s, ki, kf, sc, round(t_end / TS), {"sat": 0, "fb": 1}[g["method"]], True,
                           g["ufls"], rec_every, tab, aux0(pv), pv)
    keys = ["f min [Hz]", "max |i1| [pu]", "time over Imax(t)+0.5% [s]", "GFM extra energy [GW s]",
            "UFLS shed [GW]", "f at 20 s [Hz]", "pole slips", "max over Imax(t) [pu]", "saturations",
            "pre-trip f ptp [Hz]", "pre-trip |i1| ptp [pu]"] + (["duty clipped [s]"] if pv else [])
    return rec, dict(zip(keys, st)) | {"pg0 [pu]": pg0 / 2**14, "f0 [Hz]": rec[0, 1], "i1 at 0 [pu]": rec[0, 2]}
