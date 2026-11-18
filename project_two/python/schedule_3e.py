"""Stage 3e: clock plan of the controller split into four blocks, each with its own multipliers.

Reads the operation graph of stage 2c-4 and keeps the controller operations (the sine and cosine come from
the NCO, ready at c = 2 and 3). Every result is registered: an operation started at clock t is valid from
t + latency (adder, ROM and 18 x 18 multiply 1, the wider multiplies 2), so 'valid_from' is the first clock
a consumer, in this block or another, may read it. A block's own units are the only ones it may use;
an 18 x 18 operation may also run on a wider unit.

  block 1  measurement rotation, filters, power        block 2  droop, voltage PI and feed-forward
  block 3  current limiter                              block 4  current PI, v1 rotation, phase step
"""
import csv
from pathlib import Path

RES = Path(__file__).with_name("results")
UNITS = {1: {"B": 1}, 2: {"B": 1}, 3: {"A": 1, "C": 1}, 4: {"A": 2, "B": 1}}
WIDTH = {"A": 1, "B": 2, "C": 3}                     # 18 x 18 multipliers per unit
CAN = {"A": "ABC", "B": "BC", "C": "C"}              # unit types that can run an operation class
EXT = {"th_s": 2, "th_c": 3}
OTHER = ("th_", "thg", "r1i1", "xl1i1", "bcvc", "r2i2", "xl2i2", "a1_", "ac_", "a2_", "s1_", "s2_", "s3_", "n1_",
         "nc_", "n2_", "pg", "x_m", "incg", "dxk", "pmk", "pm_m", "rdp", "dpg", "dx", "dpm", "psum", "ufls")
B2 = {"dpf", "wm1", "wop", "vref_m", "vref", "ev_r", "ip_r", "ip_i", "uv1_r", "uv1_i", "wi_r", "wi_i", "wv_r", "wv_i",
      "ff_r", "ff_i", "xw_r", "xw_i", "ir_r", "ir_i"}
B3 = {"io_r", "io_i", "sq_r", "sq_i", "m2", "lim", "norm", "seed", "y2", "uy2", "z", "y1", "mag", "scl", "exc",
      "il_r", "il_i"}


def block(n):
    if n.startswith(("sp_", "pf", "qf", "i1rot", "vcrot", "i2rot", "i1f", "vcf", "i2f")):
        return 1
    return 2 if n in B2 else 3 if n in B3 else 4


rows = [r for r in csv.DictReader(open(RES / "stage2c4_schedule.csv"))
        if not (r["op"] in ("x", "pm", "th") or r["op"].startswith(OTHER))]
ops = {r["op"]: dict(cls=r["cls"], deps=r["deps"].split()) for r in rows}
users = {n: [m for m in ops if n in ops[m]["deps"]] for n in ops}
tail = {}


def path(n):                                         # longest chain to the end, for the priority
    if n not in tail:
        tail[n] = 2 + max([path(u) for u in users[n]], default=0)
    return tail[n]


valid, busy, plan, t = dict(EXT), {}, {}, 0
while len(plan) < len(ops):
    for n in sorted(set(ops) - set(plan), key=lambda n: (-path(n), n)):
        o, b = ops[n], block(n)
        if any(valid.get(d, 99) > t for d in o["deps"]):
            continue
        unit, lat = "-", 1
        if o["cls"] in CAN:
            free = [u for u in CAN[o["cls"]] if busy.get((t, b, u), 0) < UNITS[b].get(u, 0)]
            if not free:
                continue
            busy[(t, b, free[0])] = busy.get((t, b, free[0]), 0) + 1
            unit, lat = free[0], 1 if free[0] == "A" else 2
        valid[n] = t + lat
        plan[n] = dict(op=n, block=b, cls=o["cls"], unit=unit, start=t, valid_from=t + lat, deps=" ".join(o["deps"]))
    t += 1

with open(RES / "stage3e_schedule.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["op", "block", "cls", "unit", "start", "valid_from", "deps"])
    w.writeheader()
    w.writerows(sorted(plan.values(), key=lambda p: (p["block"], p["start"], p["op"])))
print("multipliers (18 x 18):", sum(WIDTH[u] * k for b in UNITS.values() for u, k in b.items()))
for b in UNITS:
    print(f"block {b}: {sum(p['block'] == b for p in plan.values())} operations, last result valid from c = "
          f"{max(p['valid_from'] for p in plan.values() if p['block'] == b)}")
for n in ("ir_r", "il_r", "dm", "inc", "v1_r", "v1_i"):
    print(f"{n:5s} valid from c = {valid[n]}")
