"""Stage 2c-3 check: phase accumulator of 40 bits (32 integer + 8 fraction) against plain 32 bits.
Each width runs in its own process, because Numba fixes the width when it compiles.
Same closed-loop cases and criteria as 2c-1 and 2c-2, with the ROM and Newton arithmetic on.
"""
import subprocess
import sys

if len(sys.argv) > 1:
    import gfm_fixed as fx
    import verify_stage2c1 as v
    fx.HW = True
    fx.set_phase_bits(int(sys.argv[1]))
    print(f"phase accumulator {sys.argv[1]} bits")
    v.closed_loop(f"2c3_ph{sys.argv[1]}")
else:
    for bits in (40, 32):
        subprocess.run([sys.executable, __file__, str(bits)], check=True)
