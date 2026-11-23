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
| `spec_sat` | 1.2 pu for 10 s, then 1.0 pu, sat | pretrip, trip, limit, ufls, imax_step |
| `nolimit_sat` | off, sat | pretrip, trip |
| `helda_fb`, `helda_sat` | as `held_*`, trip A | pretrip, trip |
| `speca_fb` | as `spec_fb`, trip A | pretrip, trip, limit, imax_step |
| `speca_sat` | as `spec_sat`, trip A | pretrip, trip, limit, ufls, imax_step |
| `nolimita_fb`, `nolimita_sat` | as `nolimit_*`, trip A | pretrip, trip |

`cross` ends its first 1023 steps at the first grid update where x drops through the 59.0 Hz UFLS
threshold (old x above, new x below). `excess` is the first window after the limit window where |i_raw|
stays above Imax on every step, so the fb term acts all the way through. Every case starts from the same state; the cases differ only in method, limit mode and trip size.
Cases without `a` lose 3.3 GW at the trip (trip B); cases with `a` lose 1.4 GW (trip A, one nuclear unit).
With no limit, sat and fb give the same windows byte for byte (the fb term is always 0); the generator
stops with an error if they ever differ.
The trip is at step 1,000,000. Only Imax 1.0 and 1.2 pu are supported; 2 pu or more means no limit.

## PWM vectors (`pwm/`)

Made by `python/make_vectors_5c.py` (`check` compares without writing). The integer model runs with the
three-phase PWM: 20 ns ticks, 50 per step, 4 kHz carrier, double update, dead time 100 ticks. Every case
comes with vdc 2.4 pu (`_24_`) and 4.0 pu (`_40_`):

| Case | Windows |
|---|---|
| `held_fb`, `held_sat` | start, trip, limit; `held_sat_24` also clip (first 1024 steps with a clipped duty applied) |
| `spec_fb`, `spec_sat` | imax_step (the step to 1.0 pu at 11 s) |
| `helda_fb`, `helda_sat` | trip (trip A) |
| `nolimit_fb`, `nolimit_sat` | trip; sat and fb files are the same byte for byte (checked) |

Line k: k, the 22 state words, the 16 other run-internal words as above, then the 15 PWM words: init
flag (4 bits), active duty x3 and pending duty x3 (16 bits, ticks 0..6250), gate command x3 (4 bits),
dead-time count x3 (8 bits), u re and u im (Q28, 34 bits), the mean phase voltage the LCL takes in step k.

`_sig` line k: v1 re, im (34), phi_k (40), the signs used in step k (bit 0 a, 1 b, 2 c: current below
zero), the high-tick counts a, b, c (8), the pending duty made in step k x3 (16), the new u re, im (34),
cos and sin of phi_k (Q16, 18).

`pwm_config.txt`: NH, ND, TPS, H3, KN, then v1 of the start state and, for each vdc, VK, U1, U2, the
start duties and gate commands; last the current signs of the start state. The PWM files sit in their
own folder so the stage 2d batch run does not pick them up.
