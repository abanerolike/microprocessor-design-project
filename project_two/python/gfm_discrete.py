"""Stage 2a/2b: the same model stepped at a fixed 1 us, in floating point.

One step k -> k+1. Every right-hand side uses step-k values; the only exception is the LCL chain.
  1. control from step-k states -> converter voltage v1; metrics and record row k
  2. LCL, semi-implicit: i1 first, then vc with the new i1, then i2 with the new vc
  3. PI integrators and the inverter angle, forward Euler
  4. measurement and power filters, exact first-order hold: y += (1 - exp(-wc*Ts)) * (x - y)
  5. grid angle every step with the held frequency; frequency and governor every nslow steps,
     forward Euler with step nslow*Ts, driven by the mean grid power over those steps
  6. every 1024 steps (1.024 ms): UFLS timers, on the frequency at the end of the tick
Record row k holds the state at t_k and the control computed from it (input k -> output k+1).
2a: nslow = 1, delay = 0. 2b: nslow = 1024 (board slow tick), and v1 reaches the LCL
`delay` steps after the measurements it was computed from.
"""
import numpy as np
from numba import njit
import gfm_model as m

TS = 1e-6
WB = m.WB
KEYS = ["xl1", "r1", "bc", "xl2", "r2", "kpi", "kii", "kpv", "kiv", "wc1", "wc2", "dp", "dq",
        "H", "D", "R", "K", "Tg", "cap", "xg", "rg", "r", "p0", "trip", "t_trip",
        "imax", "imax_cont", "t_short", "ks", "kvi", "ith", "xr"]
METHOD = {"sat": 0, "fb": 1, "vi": 2}
UFLS = np.array(m.UFLS)
REC = ["t", "f", "i1", "iref", "imax", "p_gfm_gw", "dtheta", "shed_gw"]


def params(g):
    d = m.DEV | g
    return np.array([np.inf if (k == "cap" and d[k] is None) else d[k] for k in KEYS])


@njit(fastmath=False)
def run(c, rr, p, meth, n, pg0, couple, ufls_on, rec_every, tab, nslow, delay):
    (xl1, r1, bc, xl2, r2, kpi, kii, kpv, kiv, wc1, wc2, dp, dq, H, D, R, K, Tg, cap,
     xg, rg, r, p0, trip, t_trip, imax0, imax_cont, t_short, ks, kvi, ith, xr) = p
    i1, vc, i2, i1f, vcf, i2f, uv, ui = c
    pf, qf, th, thg, x, pm = rr
    xl2t, r2t = xl2 + xg, r2 + rg
    a1, ac, a2 = TS * WB / xl1, TS * WB / bc, TS * WB / xl2t
    af1, af2 = 1 - np.exp(-wc1 * TS), 1 - np.exp(-wc2 * TS)
    shed, psum = 0.0, 0.0
    vbuf = np.zeros(delay + 1, dtype=np.complex128)
    armed = np.ones(tab.shape[0])
    timers = np.zeros(tab.shape[0])
    rec = np.zeros(((n + rec_every - 1) // rec_every, 8))
    fmin, i1max, t_over, energy, omax = 60.0, 0.0, 0.0, 0.0, 0.0
    dmin, dmax = th - thg, th - thg

    for k in range(n):
        t = k * TS
        # 1. control
        rot = np.exp(-1j * th)
        w = 1 + dp * (p0 - pf)
        vref = (1 - dq * qf) + 0j
        if meth == 2:
            vref -= kvi * max(abs(i1f) - ith, 0.0) * (1 + 1j * xr) * i1f
        ip = kpv * (vref - vcf)
        ff = 1j * w * bc * vcf + i2f
        iraw = ip + uv + ff
        imax = imax0 if t < t_trip + t_short else imax_cont
        mag = abs(iraw)
        ilim = iraw * min(1.0, imax / max(mag, 1e-9))
        wth = w - ks * max(mag - imax, 0.0) if meth == 1 else w
        v1 = (vcf + kpi * (ilim - i1f) + ui + 1j * w * xl1 * i1f) / rot
        if k == 0:
            vbuf[:] = v1
        vbuf[k % (delay + 1)] = v1
        v1 = vbuf[(k + 1) % (delay + 1)]
        vg = np.exp(1j * thg)
        pgrid = (vg * np.conj(i2)).real

        # running metrics and sparse records, all at step k
        f = 60 * (1 + x)
        if t >= t_trip:
            a = abs(i1)
            fmin = min(fmin, f)
            i1max = max(i1max, a)
            omax = max(omax, a - imax)
            if a - imax > 0.005 * imax:
                t_over += TS
            energy += TS * r * (pgrid - pg0) * 80
            dmin, dmax = min(dmin, th - thg), max(dmax, th - thg)
        if k % rec_every == 0:
            rec[k // rec_every] = (t, f, abs(i1), mag, imax, r * (pgrid - pg0) * 80, th - thg, shed * 80)

        # 2. LCL, semi-implicit
        i1n = i1 + a1 * (v1 - vc - r1 * i1 - 1j * xl1 * i1)
        vcn = vc + ac * (i1n - i2 - 1j * bc * vc)
        i2n = i2 + a2 * (vcn - vg - r2t * i2 - 1j * xl2t * i2)

        # 3. integrators and angle
        uv += TS * (kiv * (vref - vcf) + kiv / kpv * (ilim - iraw))
        ui += TS * kii * (ilim - i1f)
        th += TS * WB * (wth - 1)

        # 4. filters
        sp = vcf * np.conj(i2f)
        i1f += af1 * (i1 * rot - i1f)
        vcf += af1 * (vc * rot - vcf)
        i2f += af1 * (i2 * rot - i2f)
        pf += af2 * (sp.real - pf)
        qf += af2 * (sp.imag - qf)
        i1, vc, i2 = i1n, vcn, i2n

        # 5. grid
        if couple:
            thg += TS * WB * x
            psum += pgrid
            if (k + 1) % nslow == 0:
                tr = trip if t >= t_trip else 0.0
                dx = (pm - tr - D * x + r * (psum / nslow - pg0) + shed) / (2 * H)
                dpm = (-K / R * x - pm) / Tg
                if pm >= cap and dpm > 0:
                    dpm = 0.0
                x += nslow * TS * dx
                pm += nslow * TS * dpm
                psum = 0.0

        # 6. UFLS on the 1.024 ms tick
        if ufls_on and (k + 1) % 1024 == 0:
            fe = 60 * (1 + x)
            for j in range(tab.shape[0]):
                if armed[j] > 0:
                    timers[j] = timers[j] + 1024 * TS if fe < tab[j, 0] else 0.0
                    if timers[j] >= tab[j, 1] - 1e-9:
                        shed += tab[j, 2]
                        armed[j] = 0.0

    c_out = np.array([i1, vc, i2, i1f, vcf, i2f, uv, ui])
    r_out = np.array([pf, qf, th, thg, x, pm])
    stats = np.array([fmin, i1max, t_over, energy, shed * 80, 60 * (1 + x), (dmax - dmin) // (2 * np.pi), omax])
    return c_out, r_out, rec, stats


def simulate(t_end=20.0, rec_every=1024, nslow=1, delay=0, **kw):
    """Common start (continuous settle, then 1 s of discrete settle), then the trip run."""
    g = m.GRID | kw
    y, _ = m.settle(g)
    s = m.unpack(y)
    c = np.array([s[k] for k in m.C_NAMES])
    rr = np.array([s[k] for k in m.R_NAMES])
    p0 = params(g | dict(t_trip=1e9, method="sat"))
    c, rr, _, _ = run(c, rr, p0, 0, 1_000_000, 0.0, False, False, 1_000_000, UFLS, 1, delay)
    pg0 = (np.exp(1j * rr[3]) * np.conj(c[2])).real
    c, rr, rec, st = run(c, rr, params(g), METHOD[g["method"]], int(round(t_end / TS)),
                         pg0, True, g["ufls"], rec_every, UFLS, nslow, delay)
    if not (np.isfinite(c).all() and np.isfinite(rr).all() and np.isfinite(st).all()):
        st[:] = np.nan   # diverged: the running metrics are meaningless
    return rec, dict(zip(["f min [Hz]", "max |i1| [pu]", "time over Imax(t)+0.5% [s]",
                          "GFM extra energy [GW s]", "UFLS shed [GW]", "f at 20 s [Hz]",
                          "pole slips", "max over Imax(t) [pu]"], st))
