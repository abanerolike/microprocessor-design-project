# Test vectors

Made by `python/make_vectors_2d.py`. All values are integers in hex (two's complement), so a testbench
can read them with `hread` and compare bit by bit.

## Files

| File | Content |
|---|---|
| `rom_sin.hex` | 1024 sine values, Q(18,16). Cosine uses address + 256 |
| `rom_seed.hex` | 192 seeds for 1/sqrt, u in [1, 4) in steps of 1/64, Q17 |
| `limcases.txt` | 198 limiter edge cases, one per line: Imax, enable, i_raw (re, im), then the expected limit flag, excess, limited reference (re, im) |
| `<case>_start.txt` | Integer state after the float settle (decimal). Made once, then only read |
| `<case>_windows.txt` | Start step of each window. Found once, then only read |
| `<case>_config.txt` | One 48-bit value per line, name after it: constants and their F, phase constants, method, `limit_enabled`, scenario, UFLS table |
| `<case>_<window>.txt` | One line per step: step number k (decimal), 22 state words, power sum, shed, 7 UFLS tick counters, 7 armed flags |
| `<case>_<window>_sig.txt` | Main node values of the same step (v1, limited reference, limit flag, excess, speed, phase steps, grid power, sin and cos), then the values passed between the controller blocks (i_raw, w - 1, cross terms, voltage PI terms) |

Line k is the state at the start of step k. The next line is the result of that step, so the last line
of a window is the state after its last step. Each window is 2048 steps.

## State word order

i1 (re, im), vc (re, im), i2 (re, im), i1f, vcf, i2f, uv, ui (re, im each), pf, qf: Q(32,28).
th, thg: 40-bit phase. x, pm: Q(32,31). Power sum: 28 bits. Shed: Q(32,31).

## Cases and windows

| Case | Limit | Windows |
|---|---|---|
| `held_fb` | 1.2 pu, fb | pretrip, trip, limit, excess |
| `held_sat` | 1.2 pu, sat | pretrip, trip, limit, ufls, cross |
| `spec_fb` | 1.2 pu for 10 s, then 1.0 pu, fb | pretrip, trip, limit, imax_step |
| `nolimit_fb` | off (`limit_enabled` = 0) | pretrip, trip |

`cross` ends its first 1023 steps at the first grid update where x drops through the 59.0 Hz UFLS
threshold (old x above, new x below). `excess` is the first window after the limit window where |i_raw|
stays above Imax on every step, so the fb term acts all the way through. The trip is at step 1,000,000. Only Imax 1.0 and 1.2 pu are supported; 2 pu or more means no limit.
