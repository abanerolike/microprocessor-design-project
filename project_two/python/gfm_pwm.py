"""Stage 5a: the 2b model (grid every 1.024 ms) with a switching three-phase converter.

The controller still runs every 1 us and gives v1 in the frame turning at nominal speed. The LCL is
stepped `sub` times per 1 us (h = 1 us / sub); everything else stays on the 1 us step.
  mode 0: average model, v1 goes straight into the LCL (sub = 1 is gfm_discrete with nslow = 1024)
  mode 1: sine-triangle PWM, natural sampling: each sub-step compares the phase reference
          Re(v1 e^{j(w0 t - 2 pi x / 3)}) with a centre-aligned carrier
Carrier: half period N = 125 us / h sub-steps, counter 0..N..1, so one period is exactly 2N.
Duty d = 1/2 + v_x / vdc, clipped to 0..1 (time with a clipped duty applied and clipped loads counted). Upper switch on when d N > counter.
Dead time: a switch turns off at once and turns on nd sub-steps after its command; while both are off
the leg sits on the diode the phase current flows through: i_x > 0 (out of the leg) -> -vdc/2,
i_x < 0 -> +vdc/2, i_x = 0 -> -vdc/2, and 0 (mid point) when |i_x| < zth (zth = 0: sign only).
Phase voltage = leg voltage minus the mean of the three legs (three wires), then back to the frame:
v = 2/3 sum v_x e^{-j(w0 t - 2 pi x / 3)}. Voltages are in pu of the phase peak, 480 sqrt(2/3) V.
"""
import numpy as np
from numba import njit
import gfm_model as m
import gfm_discrete as q

TS, WB = q.TS, q.WB
A3 = np.exp(-2j * np.pi / 3 * np.arange(3))      # phase shifts of a, b, c
VBASE = 480 * np.sqrt(2 / 3)


@njit(fastmath=False)
def run(c, rr, p, meth, n, pg0, ufls_on, tab, sub, mode, vdc, nd, zth, nlog, pe, pw, upd, late):
    (xl1, r1, bc, xl2, r2, kpi, kii, kpv, kiv, wc1, wc2, dp, dq, H, D, R, K, Tg, cap,
     xg, rg, r, p0, trip, t_trip, imax0, imax_cont, t_short, ks, kvi, ith, xr) = p
    i1, vc, i2, i1f, vcf, i2f, uv, ui = c
    pf, qf, th, thg, x, pm = rr
    h = TS / sub
    xl2t, r2t = xl2 + xg, r2 + rg
    a1, ac, a2 = h * WB / xl1, h * WB / bc, h * WB / xl2t
    af1, af2 = 1 - np.exp(-wc1 * TS), 1 - np.exp(-wc2 * TS)
    a3 = np.exp(-2j * np.pi / 3 * np.arange(3))
    nh = 125 * sub * pw // pe                       # PWM ticks: pw per decision, decisions every pe sub-steps
    acc = np.zeros(3)
    dl = np.full(3, 0.5)                            # duty register (upd 1, 2)
    v1p, up, um = 0j, 0j, 0j                        # late: last step's v1; last and this step's mean voltage
    ab = np.zeros(3)                                # applied phase voltages (log)
    cmd = np.zeros(3, dtype=np.bool_)
    cnt = np.full(3, nd)
    leg = np.zeros(3)
    shed, psum = 0.0, 0.0
    armed = np.ones(tab.shape[0])
    timers = np.zeros(tab.shape[0])
    fmin, i1max, iabc, t_over, energy, omax, v1max = 60.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
    nclip, nload, tclip = 0, 0, -1.0
    dc = np.zeros(3, dtype=np.bool_)                # the duty in the register was clipped
    dmin, dmax = th - thg, th - thg
    ilog = np.zeros((nlog, 2), dtype=np.complex128)  # i1 and vc at each 1 us step for t < t_pre
    tlog = np.zeros(nlog)                           # grid angle
    plog = np.zeros(nlog)                           # largest |i1| inside each step
    glog = np.zeros(nlog)                           # grid power at each step
    vlog = np.zeros((nlog * sub, 3)) if nlog * sub <= 4_000_000 else np.zeros((1, 3))
    for k in range(n):
        t = k * TS
        rot = np.exp(-1j * th)
        w = 1 + dp * (p0 - pf)
        vref = (1 - dq * qf) + 0j
        ip = kpv * (vref - vcf)
        ff = 1j * w * bc * vcf + i2f
        iraw = ip + uv + ff
        imax = imax0 if t < t_trip + t_short else imax_cont
        mag = abs(iraw)
        ilim = iraw * min(1.0, imax / max(mag, 1e-9))
        wth = w - ks * max(mag - imax, 0.0) if meth == 1 else w
        v1 = (vcf + kpi * (ilim - i1f) + ui + 1j * w * xl1 * i1f) / rot
        v1max = max(v1max, abs(v1))
        if k == 0:
            v1p = v1
        vd = v1p if late else v1                    # v1 the duty register can load during this step
        vg = np.exp(1j * thg)
        pgrid = (vg * np.conj(i2)).real
        f = 60 * (1 + x)
        if k < nlog:
            ilog[k, 0], ilog[k, 1], tlog[k] = i1, vc, thg
            glog[k] = pgrid
        if t >= t_trip:
            fmin = min(fmin, f)
            energy += TS * r * (pgrid - pg0) * 80
            dmin, dmax = min(dmin, th - thg), max(dmax, th - thg)

        # control state updates use step-k values only
        uvn = uv + TS * (kiv * (vref - vcf) + kiv / kpv * (ilim - iraw))
        uin = ui + TS * kii * (ilim - i1f)
        thn = th + TS * WB * (wth - 1)
        sp = vcf * np.conj(i2f)
        i1f += af1 * (i1 * rot - i1f)
        vcf += af1 * (vc * rot - vcf)
        i2f += af1 * (i2 * rot - i2f)
        pf += af2 * (sp.real - pf)
        qf += af2 * (sp.imag - qf)
        uv, ui, th = uvn, uin, thn

        # LCL, sub-steps
        pk = 0.0
        for j in range(sub):
            mm = k * sub + j
            e = np.exp(1j * (WB * mm * h))
            u = v1
            if mode >= 1 and mm % pe == 0:
                acc = np.zeros(3)
                for tk in range(pw):                    # pw PWM ticks inside one sub-step
                    mt = mm // pe * pw + tk
                    et = np.exp(1j * (WB * mt * h * pe / pw))
                    qq = mt % (2 * nh)
                    cr = qq if qq <= nh else 2 * nh - qq
                    load = upd == 0 or qq == 0 or (upd == 2 and qq == nh)
                    for ph in range(3):
                        if load:
                            d = 0.5 + (vd * et * a3[ph]).real / vdc
                            dc[ph] = d < 0.0 or d > 1.0
                            dl[ph] = min(max(d, 0.0), 1.0)
                        d = dl[ph]
                        if mode == 2:                   # held duty applied as its average, no switching
                            acc[ph] += (2 * d - 1) * vdc / 2 / pw
                            continue
                        cm = d * nh > cr
                        if cm != cmd[ph]:
                            cmd[ph] = cm
                            cnt[ph] = 0
                        if cnt[ph] >= nd:
                            leg[ph] = vdc / 2 if cm else -vdc / 2
                        else:
                            ix = (i1 * et * a3[ph]).real
                            if abs(ix) < zth:
                                leg[ph] = 0.0
                            else:
                                leg[ph] = vdc / 2 if ix < 0 else -vdc / 2
                        cnt[ph] = min(cnt[ph] + 1, nd)
                        acc[ph] += leg[ph] / pw
                    if dc[0] or dc[1] or dc[2]:             # clipped duty applied during this tick
                        nclip += 1
                        nload += load
                        if tclip < 0:
                            tclip = t + (j + tk / pw) * h
            if mode >= 1:
                vm = (acc[0] + acc[1] + acc[2]) / 3
                u = 0j
                for ph in range(3):
                    ab[ph] = acc[ph] - vm
                    u += ab[ph] * np.conj(e * a3[ph])
                u *= 2 / 3
            else:
                for ph in range(3):
                    ab[ph] = (u * e * a3[ph]).real
            um += u / sub
            if late and k > 0:                          # the mean voltage of a step is ready at its end:
                u = up                                  # the plant takes last step's, 1 us later, as a
                for ph in range(3):                     # frame value; ab is that value seen in abc now
                    ab[ph] = (u * e * a3[ph]).real
            if mm < vlog.shape[0]:
                vlog[mm] = ab                           # the phase voltages the plant gets
            i1n = i1 + a1 * (u - vc - r1 * i1 - 1j * xl1 * i1)
            vcn = vc + ac * (i1n - i2 - 1j * bc * vc)
            i2 = i2 + a2 * (vcn - vg - r2t * i2 - 1j * xl2t * i2)
            i1, vc = i1n, vcn
            a = abs(i1)
            pk = max(pk, a)
            if t >= t_trip:
                ea = np.exp(1j * (WB * (mm + 1) * h))
                for ph in range(3):
                    iabc = max(iabc, abs((i1 * ea * a3[ph]).real))
        if k < nlog:
            plog[k] = pk
        if t >= t_trip:
            i1max = max(i1max, pk)
            omax = max(omax, pk - imax)
            if pk - imax > 0.005 * imax:
                t_over += TS

        v1p = v1
        up, um = um, 0j

        # grid every 1.024 ms
        thg += TS * WB * x
        psum += pgrid
        if (k + 1) % 1024 == 0:
            tr = trip if t >= t_trip else 0.0
            dx = (pm - tr - D * x + r * (psum / 1024 - pg0) + shed) / (2 * H)
            dpm = (-K / R * x - pm) / Tg
            if pm >= cap and dpm > 0:
                dpm = 0.0
            x += 1024 * TS * dx
            pm += 1024 * TS * dpm
            psum = 0.0
            if ufls_on:
                fe = 60 * (1 + x)
                for jj in range(tab.shape[0]):
                    if armed[jj] > 0:
                        timers[jj] = timers[jj] + 1024 * TS if fe < tab[jj, 0] else 0.0
                        if timers[jj] >= tab[jj, 1] - 1e-9:
                            shed += tab[jj, 2]
                            armed[jj] = 0.0

    st = np.array([fmin, i1max, iabc, t_over, energy, shed * 80, 60 * (1 + x), (dmax - dmin) // (2 * np.pi),
                   omax, v1max, nclip * h * pe / pw, nload, tclip])
    return np.array([i1, vc, i2, i1f, vcf, i2f, uv, ui]), np.array([pf, qf, th, thg, x, pm]), st, \
        ilog, plog, glog, vlog, tlog


STATS = ["f min [Hz]", "max |i1| [pu]", "max phase |i1| [pu]", "time over Imax(t)+0.5% [s]",
         "GFM extra energy [GW s]", "UFLS shed [GW]", "f at end [Hz]", "pole slips", "max over Imax(t) [pu]",
         "max |v1| command [pu]", "clipped time [s]", "clipped loads", "first clip [s]"]


def start(**kw):
    """Same start as gfm_discrete.simulate: continuous settle, then 1 s of discrete settle."""
    g = m.GRID | kw
    y, _ = m.settle(g)
    s = m.unpack(y)
    c = np.array([s[k] for k in m.C_NAMES])
    rr = np.array([s[k] for k in m.R_NAMES])
    c, rr, _, _ = q.run(c, rr, q.params(g | dict(t_trip=1e9, method="sat")), 0, 1_000_000, 0.0, False, False,
                        1_000_000, q.UFLS, 1, 0)
    return g, c, rr, (np.exp(1j * rr[3]) * np.conj(c[2])).real


def simulate(t_end=20.0, sub=1, mode=1, vdc=4.0, nd=0, zth=0.0, t_pre=1.0, s0=None, pe=1, pw=1, upd=0, late=False, **kw):
    """Trip run from the common start. s0 = start(**kw) can be passed to reuse the settle."""
    g, c, rr, pg0 = s0 if s0 is not None else start(**kw)
    nlog = int(round(t_pre / TS))
    c, rr, st, ilog, plog, glog, vlog, tlog = run(c, rr, q.params(g), q.METHOD[g["method"]], int(round(t_end / TS)),
                                                  pg0, g["ufls"], q.UFLS, sub, mode, vdc, nd, zth, nlog, pe, pw, upd, late)
    if not (np.isfinite(c).all() and np.isfinite(rr).all()):
        st[:] = np.nan
    return dict(zip(STATS, st)), dict(i1=ilog[:, 0], vc=ilog[:, 1], peak=plog, pg=glog, v=vlog, thg=tlog, end=(c, rr))


def lcl_abc(i0, vc0, i20, v, thg, sub, g):
    """Reference: each phase of the LCL in the fixed abc frame, stepped exactly for inputs held over
    a sub-step (matrix exponential). v = applied phase voltages per sub-step, thg = grid angle per
    1 us step (grid voltage taken at the middle of the sub-step). Returns i1, vc, i2 per phase after
    every sub-step."""
    d = m.DEV
    xl2t, r2t = d["xl2"] + g["xg"], d["r2"] + g["rg"]
    h = TS / sub
    A = WB * np.array([[-d["r1"] / d["xl1"], -1 / d["xl1"], 0], [1 / d["bc"], 0, -1 / d["bc"]],
                       [0, 1 / xl2t, -r2t / xl2t]])
    Bm = WB * np.array([[1 / d["xl1"], 0], [0, 0], [0, -1 / xl2t]])
    M = np.zeros((5, 5))
    M[:3, :3], M[:3, 3:] = A * h, Bm * h
    from scipy.linalg import expm
    E = expm(M)
    Ad, Bd = E[:3, :3], E[:3, 3:]
    return _lcl_abc(np.array([i0, vc0, i20]), v, thg, sub, h, Ad, Bd)


@njit(fastmath=False)
def _lcl_abc(z0, v, thg, sub, h, Ad, Bd):
    n = v.shape[0]
    a3 = np.exp(-2j * np.pi / 3 * np.arange(3))
    out = np.zeros((n, 3, 3))
    z = np.zeros((3, 3))
    for ph in range(3):
        for s in range(3):
            z[ph, s] = (z0[s] * a3[ph]).real     # t = 0 of the window: rotation angle 0
    for mm in range(n):
        tm = (mm + 0.5) * h
        g = np.exp(1j * (thg[mm // sub] + WB * tm))
        for ph in range(3):
            u0, u1 = v[mm, ph], (g * a3[ph]).real
            zn = Ad @ z[ph] + Bd[:, 0] * u0 + Bd[:, 1] * u1
            z[ph] = zn
            out[mm, ph] = zn
    return out
