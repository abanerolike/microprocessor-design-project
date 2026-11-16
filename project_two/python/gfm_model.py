"""Grid-forming inverter on a reduced grid frequency model (average model, dq frame).

Device side is in per unit of one 1 MVA, 480 V unit (Westman and Hadidi, Energies 2023,
Table A1). Grid side is in per unit of S_sys = 80 GVA. Time is in seconds.
"""
import numpy as np
from scipy.integrate import solve_ivp

F0 = 60.0
WB = 2 * np.pi * F0
ZB = 480**2 / 1e6

# LCL and controller gains, converted from SI to device pu
DEV = dict(
    xl1=WB * 30e-6 / ZB, r1=0.1e-3 / ZB, bc=WB * 1.9e-3 * ZB,
    xl2=WB * 132e-6 / ZB, r2=0.0037 / ZB,
    kpi=0.05 / ZB, kii=2.5 / ZB, kpv=10 * ZB, kiv=1000 * ZB,
    wc1=2500.0, wc2=100.0, dp=0.01, dq=0.05,
)

# Grid scenario defaults (see spec v1 in the project notes)
GRID = dict(H=3.3, D=2.0, R=0.05, K=0.3, Tg=3.0, cap=None,
            xg=0.2, rg=0.02, r=0.0, p0=0.0, trip=1.4 / 80, t_trip=1.0,
            imax=1.2, imax_cont=1.0, t_short=10.0, ufls=True)

# UFLS: (Hz, delay in s, shed fraction of total load)
UFLS = [(59.0, 0.1, 0.06), (58.8, 0.1, 0.06), (58.6, 0.1, 0.06),
        (58.4, 0.1, 0.06), (58.2, 0.1, 0.06), (58.0, 0.1, 0.05), (59.0, 12.0, 0.04)]

# state layout: 8 complex values, then 6 real values
C_NAMES = ["i1", "vc", "i2", "i1f", "vcf", "i2f", "uv", "ui"]
R_NAMES = ["pf", "qf", "th", "thg", "x", "pm"]


def unpack(y):
    c = y[:16:2] + 1j * y[1:16:2]
    return dict(zip(C_NAMES, c)) | dict(zip(R_NAMES, y[16:]))


def pack(s):
    y = np.zeros(22)
    c = np.array([s[k] for k in C_NAMES])
    y[:16:2], y[1:16:2] = c.real, c.imag
    y[16:] = [s[k] for k in R_NAMES]
    return y


def control(s, g, t):
    """Droop, voltage PI, current limiter and current PI. Returns signals in the controller frame."""
    d = DEV
    rot = np.exp(-1j * s["th"])
    w = 1 + d["dp"] * (g["p0"] - s["pf"])
    vref = 1 - d["dq"] * s["qf"]
    i_raw = (d["kpv"] * (vref - s["vcf"]) + s["uv"]
             + 1j * w * d["bc"] * s["vcf"] + s["i2f"])
    imax = g["imax"] if t < g["t_trip"] + g["t_short"] else g["imax_cont"]
    i_lim = i_raw * min(1.0, imax / max(abs(i_raw), 1e-9))
    v1 = s["vcf"] + d["kpi"] * (i_lim - s["i1f"]) + s["ui"] + 1j * w * d["xl1"] * s["i1f"]
    return dict(rot=rot, w=w, vref=vref, i_raw=i_raw, i_lim=i_lim, imax=imax, v1=v1 / rot)


def rhs(t, y, g, pg0, shed, couple):
    d, s = DEV, unpack(y)
    c = control(s, g, t)
    vg = np.exp(1j * s["thg"])
    xl2, r2 = d["xl2"] + g["xg"], d["r2"] + g["rg"]

    # LCL in a frame turning at nominal speed
    di1 = WB / d["xl1"] * (c["v1"] - s["vc"] - d["r1"] * s["i1"] - 1j * d["xl1"] * s["i1"])
    dvc = WB / d["bc"] * (s["i1"] - s["i2"] - 1j * d["bc"] * s["vc"])
    di2 = WB / xl2 * (s["vc"] - vg - r2 * s["i2"] - 1j * xl2 * s["i2"])

    # measurement filters act in the controller frame
    rot = c["rot"]
    di1f = d["wc1"] * (s["i1"] * rot - s["i1f"])
    dvcf = d["wc1"] * (s["vc"] * rot - s["vcf"])
    di2f = d["wc1"] * (s["i2"] * rot - s["i2f"])
    sp = s["vcf"] * np.conj(s["i2f"])
    dpf = d["wc2"] * (sp.real - s["pf"])
    dqf = d["wc2"] * (sp.imag - s["qf"])

    # back-calculation anti-windup: the clipped part bleeds out of the voltage integrator
    duv = d["kiv"] * (c["vref"] - s["vcf"]) + d["kiv"] / d["kpv"] * (c["i_lim"] - c["i_raw"])
    dui = d["kii"] * (c["i_lim"] - s["i1f"])
    dth = WB * (c["w"] - 1)

    # grid: change from the pre-trip balance, in system pu
    pgrid = (vg * np.conj(s["i2"])).real
    dp_gfm = g["r"] * (pgrid - pg0) if couple else 0.0
    trip = g["trip"] if t >= g["t_trip"] else 0.0
    dx = (s["pm"] - trip - g["D"] * s["x"] + dp_gfm + shed) / (2 * g["H"]) if couple else 0.0
    dpm = (-g["K"] / g["R"] * s["x"] - s["pm"]) / g["Tg"] if couple else 0.0
    if g["cap"] is not None and s["pm"] >= g["cap"] and dpm > 0:
        dpm = 0.0
    dthg = WB * s["x"]

    dc = [di1, dvc, di2, di1f, dvcf, di2f, duv, dui]
    return pack(dict(zip(C_NAMES, dc)) | dict(zip(R_NAMES, [dpf, dqf, dth, dthg, dx, dpm])))


def settle(g, t_end=3.0):
    """Run the device alone on a 60 Hz grid until it sits at P0."""
    s = {k: 0j for k in C_NAMES} | {k: 0.0 for k in R_NAMES}
    s.update(vc=1, vcf=1, ui=1)
    g0 = g | dict(t_trip=1e9)
    sol = solve_ivp(rhs, (0, t_end), pack(s), args=(g0, 0.0, 0.0, False),
                    method="LSODA", rtol=1e-8, atol=1e-10)
    y = sol.y[:, -1]
    s = unpack(y)
    return y, (np.exp(1j * s["thg"]) * np.conj(s["i2"])).real


def simulate(t_end=20.0, rtol=1e-6, seg=1.024e-3, **kw):
    """Closed loop run. The trip happens at t_trip. UFLS is checked every seg (board slow tick)."""
    g = GRID | kw
    y, pg0 = settle(g)
    shed, armed, timers = 0.0, [True] * len(UFLS), [0.0] * len(UFLS)
    out, t = [], 0.0
    while t < t_end - 1e-9:
        t1 = min(t + seg, t_end)
        sol = solve_ivp(rhs, (t, t1), y, args=(g, pg0, shed, True), method="LSODA",
                        rtol=rtol, atol=rtol * 1e-2, dense_output=False)
        for k in range(sol.t.size):
            out.append(record(sol.t[k], sol.y[:, k], g, pg0, shed))
        y, t = sol.y[:, -1], t1
        f = F0 * (1 + y[20])
        for i, (fset, delay, frac) in enumerate(UFLS):
            if not (g["ufls"] and armed[i]):
                continue
            timers[i] = timers[i] + seg if f < fset else 0.0
            if timers[i] >= delay - 1e-9:
                shed += frac
                armed[i] = False
    return np.array(out), pg0


def record(t, y, g, pg0, shed):
    s = unpack(y)
    c = control(s, g, t)
    vg = np.exp(1j * s["thg"])
    pgrid = (vg * np.conj(s["i2"])).real
    dth = np.angle(np.exp(1j * (s["th"] - s["thg"])))
    return [t, F0 * (1 + s["x"]), abs(s["i1"]), abs(c["i_lim"]) < abs(c["i_raw"]) - 1e-9,
            pgrid, g["r"] * (pgrid - pg0) * 80, s["pm"] * 80, shed * 80, dth, abs(s["vc"]),
            abs(c["i_raw"]), c["imax"]]


COLS = ["t", "f", "i1", "limited", "p_grid", "p_gfm_gw", "pm_gw", "shed_gw", "dtheta", "vc",
        "iref", "imax"]
