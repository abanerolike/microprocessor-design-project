LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE ieee.math_real.ALL;

-- Rounding, saturation and fixed constants shared by the model modules. Every constant is an 18-bit
-- integer c with its own fraction bits F (value = c / 2^F), the same numbers the vector files carry.
PACKAGE gfm_pkg IS
	TYPE counts IS ARRAY (0 TO 6) OF INTEGER RANGE 0 TO 16383;
	TYPE values IS ARRAY (0 TO 6) OF INTEGER;
	TYPE words IS ARRAY (NATURAL RANGE <>) OF SIGNED(31 DOWNTO 0);
	TYPE seeds IS ARRAY (0 TO 191) OF INTEGER RANGE 0 TO 131071;
	TYPE segs IS ARRAY (0 TO 7) OF STD_LOGIC_VECTOR(6 DOWNTO 0);   -- HEX0..7, gfedcba, active low

	-- grid model for H = 3.3 s, D = 2, K/R = 6, Tg = 3 s, r = 10 %, all per 1.024 ms update.
	-- A new H (or D, K, R, Tg, r) changes both the integer and its F, so the two are kept together.
	CONSTANT GH  : INTEGER := 83296;     -- 1024 Ts / 2H
	CONSTANT FGH : INTEGER := 29;
	CONSTANT GT  : INTEGER := 91626;     -- 1024 Ts / Tg
	CONSTANT FGT : INTEGER := 28;
	CONSTANT KR  : INTEGER := 98304;     -- K / R
	CONSTANT FKR : INTEGER := 14;
	CONSTANT DD  : INTEGER := 65536;     -- load damping D
	CONSTANT FDD : INTEGER := 15;
	CONSTANT RR  : INTEGER := 104858;    -- r
	CONSTANT FRR : INTEGER := 20;
	CONSTANT KPH : INTEGER := 128849;    -- phase count per microsecond at 1 pu speed
	CONSTANT FKP : INTEGER := -9;

	-- LCL filter and grid tie, semi-implicit Euler per microsecond (SCR 5)
	CONSTANT A1  : INTEGER := 128849;    -- Ts wb / xL1
	CONSTANT FA1 : INTEGER := 24;
	CONSTANT AC  : INTEGER := 76650;     -- Ts wb / bC
	CONSTANT FAC : INTEGER := 25;
	CONSTANT A2  : INTEGER := 121636;    -- Ts wb / (xL2 + xg)
	CONSTANT FA2 : INTEGER := 27;
	CONSTANT BC  : INTEGER := 86524;     -- bC, capacitor cross term
	CONSTANT FBC : INTEGER := 19;
	CONSTANT XL1 : INTEGER := 102944;
	CONSTANT FX1 : INTEGER := 21;
	CONSTANT R1  : INTEGER := 116508;
	CONSTANT FR1 : INTEGER := 28;
	CONSTANT XL2 : INTEGER := 109048;    -- xL2 + xg
	CONSTANT FX2 : INTEGER := 18;
	CONSTANT R2  : INTEGER := 75621;     -- r2 + rg
	CONSTANT FR2 : INTEGER := 21;

	-- controller: measurement and power filters, 1 - exp(-wc Ts)
	CONSTANT AF1 : INTEGER := 83781;
	CONSTANT FF1 : INTEGER := 25;
	CONSTANT AF2 : INTEGER := 107369;
	CONSTANT FF2 : INTEGER := 30;
	-- droop, voltage PI (Ts kiv for the integral, Ts kiv / kpv for anti-windup), current PI (Ts kii), fb gain ks
	CONSTANT KDP : INTEGER := 83886;     -- dp
	CONSTANT FDP : INTEGER := 23;
	CONSTANT KDQ : INTEGER := 104858;    -- dq
	CONSTANT FDQ : INTEGER := 21;
	CONSTANT KPV : INTEGER := 75497;
	CONSTANT FPV : INTEGER := 15;
	CONSTANT KIV : INTEGER := 123695;
	CONSTANT FIV : INTEGER := 29;
	CONSTANT KAW : INTEGER := 107374;
	CONSTANT FAW : INTEGER := 30;
	CONSTANT KPI : INTEGER := 113778;
	CONSTANT FPI : INTEGER := 19;
	CONSTANT KII : INTEGER := 93207;
	CONSTANT FII : INTEGER := 33;
	CONSTANT FKS : INTEGER := 19;        -- ks is an input (0 or below 0.25), always at F 19

	-- UFLS stages: frequency threshold on x (Q31), delay in 1.024 ms ticks, load shed (Q31)
	CONSTANT THR : values := (-35791394, -42949673, -50107952, -57266231, -64424509, -71582788, -35791394);
	CONSTANT LIM : counts := (98, 98, 98, 98, 98, 98, 11719);
	CONSTANT AMT : values := (128849019, 128849019, 128849019, 128849019, 128849019, 107374182, 85899346);

	-- board scenario (r = 10 %, P0 = 0.9), Q28 unless noted
	CONSTANT SP0 : INTEGER := 241591910;
	CONSTANT SDP : INTEGER := 88583700;  -- lost generation, trip B 3.3 GW, Q31
	CONSTANT SDA : INTEGER := 37580964;  -- trip A 1.4 GW
	CONSTANT SCP : INTEGER := 26843546;  -- reserve cap, Q31
	CONSTANT SPG : INTEGER := 14258;     -- pre-trip grid power, Q14
	CONSTANT SKS : INTEGER := 104858;    -- fb gain 0.2 at F 19
	CONSTANT SI0 : INTEGER := 322122547; -- 1.2 pu
	CONSTANT SI1 : INTEGER := 268435456; -- 1.0 pu, 10 s after the trip
	CONSTANT SKT : INTEGER := 1000000;   -- automatic trip step (1 s)
	CONSTANT SNC : INTEGER := 10000;     -- steps per 0.01 s
	CONSTANT SNW : INTEGER := 1000;      -- 0.01 s units from the trip to the 1.0 pu limit

	-- start state (step 0 of every case): device and controller words in vector-line order, inverter
	-- phase. The grid side starts at 0 with every UFLS stage armed.
	CONSTANT ST_D : words(0 TO 17) := (
		X"0CF1982E", X"06928922", X"0EC86F0A", X"05F0F859", X"0DEC9B09", X"0421FC72",
		X"0E75ED1F", X"0145815C", X"0FEEB90C", X"0000037E", X"0E75F0A7", X"FEA472FB",
		X"FFFFB557", X"FFFFE3EB", X"00019541", X"00002427", X"0E667C50", X"015A1CE2");
	CONSTANT ST_TH : UNSIGNED(39 DOWNTO 0) := X"0F91EB84C9";

	FUNCTION rs (v : SIGNED; n : NATURAL) RETURN SIGNED;
	FUNCTION sat (v : SIGNED; w : POSITIVE) RETURN SIGNED;
	FUNCTION op (v : SIGNED) RETURN SIGNED;
	FUNCTION seed RETURN seeds;
	CONSTANT SEED_ROM : seeds;
END gfm_pkg;

PACKAGE BODY gfm_pkg IS
	-- shift right by n, rounding half up (the half is built by a shift: 2^(n-1) may not fit an INTEGER)
	FUNCTION rs (v : SIGNED; n : NATURAL) RETURN SIGNED IS
	BEGIN
		IF n = 0 THEN
			RETURN v;
		END IF;
		RETURN SHIFT_RIGHT(v + SHIFT_LEFT(TO_SIGNED(1, v'LENGTH), n - 1), n);
	END rs;

	-- clamp to a w-bit signed range
	FUNCTION sat (v : SIGNED; w : POSITIVE) RETURN SIGNED IS
		VARIABLE r : SIGNED(w - 1 DOWNTO 0) := RESIZE(v, w);
	BEGIN
		IF RESIZE(r, v'LENGTH) /= v THEN
			r := (OTHERS => NOT v(v'LEFT));
			r(w - 1) := v(v'LEFT);
		END IF;
		RETURN r;
	END sat;

	-- Q(32,28) state to an 18-bit Q14 multiplier operand
	FUNCTION op (v : SIGNED) RETURN SIGNED IS
	BEGIN
		RETURN sat(rs(RESIZE(v, 33), 14), 18);
	END op;

	-- first guess of 1/sqrt(u) for u in [1, 4) in 192 steps of 1/64, Q17, taken at the top of each step and
	-- rounded down so it never overshoots: floor(2^20 / sqrt(n)), n = 65..256. Only n = 256 gives an exact
	-- integer; the 1e-9 keeps a square root that comes out a hair high from flooring it to one less
	FUNCTION seed RETURN seeds IS
		VARIABLE t : seeds;
	BEGIN
		FOR i IN t'RANGE LOOP
			t(i) := INTEGER(FLOOR(2.0 ** 20 / SQRT(REAL(i + 65)) + 1.0E-9));
		END LOOP;
		RETURN t;
	END seed;

	CONSTANT SEED_ROM : seeds := seed;
END gfm_pkg;
