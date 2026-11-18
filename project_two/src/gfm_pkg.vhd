LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- Rounding, saturation and fixed constants shared by the model modules. Every constant is an 18-bit
-- integer c with its own fraction bits F (value = c / 2^F), the same numbers the vector files carry.
PACKAGE gfm_pkg IS
	TYPE counts IS ARRAY (0 TO 6) OF INTEGER RANGE 0 TO 16383;
	TYPE values IS ARRAY (0 TO 6) OF INTEGER;

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

	-- UFLS stages: frequency threshold on x (Q31), delay in 1.024 ms ticks, load shed (Q31)
	CONSTANT THR : values := (-35791394, -42949673, -50107952, -57266231, -64424509, -71582788, -35791394);
	CONSTANT LIM : counts := (98, 98, 98, 98, 98, 98, 11719);
	CONSTANT AMT : values := (128849019, 128849019, 128849019, 128849019, 128849019, 107374182, 85899346);

	FUNCTION rs (v : SIGNED; n : NATURAL) RETURN SIGNED;
	FUNCTION sat (v : SIGNED; w : POSITIVE) RETURN SIGNED;
END gfm_pkg;

PACKAGE BODY gfm_pkg IS
	-- shift right by n, rounding half up
	FUNCTION rs (v : SIGNED; n : NATURAL) RETURN SIGNED IS
	BEGIN
		RETURN SHIFT_RIGHT(v + 2 ** (n - 1), n);
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
END gfm_pkg;
