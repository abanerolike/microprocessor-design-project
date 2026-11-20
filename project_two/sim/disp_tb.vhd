LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Checks disp with values whose digits are known by hand:
--   x = 0 -> 6000, the 59.0 Hz UFLS threshold -> 5900, -0.21/60 -> 5979, -21.4 and -21.6 in 0.01 Hz
--   -> 5979 and 5978 (rounding), +0.7 -> 10200 -> Err, -1 -> 0000; shed of stage 1 -> 0480, of stages
--   1..6 -> 2800, a negative shed -> Err; time 1234, 0000, 9999, 10000 -> Err; ---- on HEX3..0 before
--   the trip on both pages
--   the inputs are copied on the clock after a step pulse (one every 5 clocks here); the lowest
--   frequency shown is the lower of x and xmin (5978 when x is below xmin); the copy for the VGA text has
--   the same digits, the trip flag and the lowest x itself (not rounded)
--   all eight digits change together: x and xmin changed at once never show an old/new mix
--   the trip flag changes with the digits: 6000---- <-> 5500 5400, back and forth six times; all eight
--   digits are compared on every clock and never show anything else. The refresh period is 320 clocks (5 rounds, a multiple of the step period), so a new
--   copy always lands on the clock a round ends
--   refresh: with a 1000-clock period and x changing every 10 clocks for 3000 clocks, HEX7..4 change at
--   most 4 times (without the copy they would follow every converter round, about 47 times)
--   PK (fifth value, VGA only; expected values from the same integer rule in Python): a large i1 before
--   the trip is left out (3.0 pu, then 1.0) and a peak on the first trip step is kept (1.5 pu for one
--   step -> 1500); clamped operand at the largest i1 -> 8000, 7.9 + j7.9 pu -> ERR; a load while a round
--   runs never shows the old peak, then 1000; a peak stays after many refreshes (0.9 - j0.8 -> 1204);
--   the operand is rounded, not cut (1.00052 pu -> 1001, cut 1000);
--   i1 and t rising every step: the shown PK always belongs to the shown t (no step early or late)
-- Every case waits a refresh plus two full rounds of the converter before it compares all eight digits.
ENTITY disp_tb IS
END disp_tb;

ARCHITECTURE a OF disp_tb IS
	SIGNAL clk, pg, tr, step, load : STD_LOGIC := '0';
	SIGNAL ir, ii : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL ramp : BOOLEAN := FALSE;
	SIGNAL tn : INTEGER RANGE 0 TO 10000 := 0;                -- ramp step count
	SIGNAL ti : INTEGER RANGE 0 TO 10000;
	SIGNAL ri : SIGNED(31 DOWNTO 0);
	SIGNAL ph : INTEGER RANGE 0 TO 4 := 0;
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL x, xmin, shed : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL t : INTEGER RANGE 0 TO 10000 := 0;
	SIGNAL hex, h2 : segs;
	SIGNAL x2, lo : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL dd : STD_LOGIC_VECTOR(79 DOWNTO 0);
	SIGNAL db : STD_LOGIC_VECTOR(0 TO 4);
	SIGNAL dt : STD_LOGIC;
BEGIN
	dut : ENTITY work.disp GENERIC MAP (320) PORT MAP (clk, load, step, pg, tr, x, xmin, shed, ri, ii, ti, hex, dd,
		db, dt, lo);
	d2 : ENTITY work.disp GENERIC MAP (1000) PORT MAP (clk, '0', step, '0', '0', x2, x2, x2, x2, x2, 0, h2);

	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			ph <= (ph + 1) MOD 5;
		END IF;
	END PROCESS;
	step <= '1' WHEN ph = 4 ELSE '0';

	PROCESS (clk)                                       -- ramp: t and i1 step with the model steps
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			IF NOT ramp THEN
				tn <= 0;
			ELSIF step = '1' THEN
				tn <= tn + 1;
			END IF;
		END IF;
	END PROCESS;
	ti <= tn WHEN ramp ELSE t;
	ri <= TO_SIGNED(268435456 + 3000000 * tn, 32) WHEN ramp ELSE ir;

	PROCESS
	BEGIN
		WHILE NOT done LOOP
			clk <= '0';
			WAIT FOR 10 ns;
			clk <= '1';
			WAIT FOR 10 ns;
		END LOOP;
		WAIT;
	END PROCESS;

	PROCESS
		VARIABLE errs, n, sk, a : INTEGER := 0;
		VARIABLE last, now : STD_LOGIC_VECTOR(27 DOWNTO 0) := (OTHERS => '0');

		FUNCTION pat (c : CHARACTER) RETURN STD_LOGIC_VECTOR IS
		BEGIN
			CASE c IS
				WHEN '0' => RETURN "1000000";
				WHEN '1' => RETURN "1111001";
				WHEN '2' => RETURN "0100100";
				WHEN '3' => RETURN "0110000";
				WHEN '4' => RETURN "0011001";
				WHEN '5' => RETURN "0010010";
				WHEN '6' => RETURN "0000010";
				WHEN '7' => RETURN "1111000";
				WHEN '8' => RETURN "0000000";
				WHEN '9' => RETURN "0010000";
				WHEN 'E' => RETURN "0000110";
				WHEN 'r' => RETURN "0101111";
				WHEN ' ' => RETURN "1111111";
				WHEN OTHERS => RETURN "0111111";
			END CASE;
		END pat;

		IMPURE FUNCTION is_on (s : STRING) RETURN BOOLEAN IS   -- all eight digits equal s (HEX7 .. HEX0)
		BEGIN
			FOR i IN 0 TO 7 LOOP
				IF hex(7 - i) /= pat(s(s'LEFT + i)) THEN
					RETURN FALSE;
				END IF;
			END LOOP;
			RETURN TRUE;
		END is_on;

		PROCEDURE check (ok : BOOLEAN; m : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT m SEVERITY ERROR;
			END IF;
		END check;

		PROCEDURE pulse (SIGNAL p : OUT STD_LOGIC) IS
		BEGIN
			WAIT UNTIL clk = '1' AND clk'EVENT;
			p <= '1';
			WAIT UNTIL clk = '1' AND clk'EVENT;
			p <= '0';
		END pulse;

		FUNCTION val (v : STD_LOGIC_VECTOR(15 DOWNTO 0)) RETURN INTEGER IS   -- four BCD digits
		BEGIN
			RETURN 1000 * TO_INTEGER(UNSIGNED(v(15 DOWNTO 12))) + 100 * TO_INTEGER(UNSIGNED(v(11 DOWNTO 8)))
				+ 10 * TO_INTEGER(UNSIGNED(v(7 DOWNTO 4))) + TO_INTEGER(UNSIGNED(v(3 DOWNTO 0)));
		END val;

		IMPURE FUNCTION pkv RETURN INTEGER IS
		BEGIN
			RETURN val(dd(79 DOWNTO 64));
		END pkv;

		PROCEDURE show (s : STRING) IS               -- s = HEX7 .. HEX0
		BEGIN
			FOR i IN 1 TO 500 LOOP                   -- a refresh (320) and two rounds (80)
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
			WAIT FOR 1 ns;
			FOR i IN 0 TO 7 LOOP
				IF hex(7 - i) /= pat(s(s'LEFT + i)) THEN
					errs := errs + 1;
					REPORT "HEX" & INTEGER'IMAGE(7 - i) & " wrong, expected " & s SEVERITY ERROR;
				END IF;
			END LOOP;
		END show;
	BEGIN
		show("6000----");                            -- before the trip
		tr <= '1';
		xmin <= TO_SIGNED(THR(0), 32);
		show("60005900");
		x <= TO_SIGNED(-7516193, 32);
		xmin <= TO_SIGNED(-7659352, 32);
		show("59795979");
		xmin <= TO_SIGNED(-7730936, 32);
		show("59795978");
		tr <= '0';
		x <= (OTHERS => '0');
		show("6000----");
		FOR k IN 1 TO 6 LOOP                         -- trip flag and digits change together
			tr <= '1';
			x <= TO_SIGNED(-178956971, 32);          -- 55.00 Hz
			xmin <= TO_SIGNED(-214748365, 32);       -- 54.00 Hz
			IF k MOD 2 = 0 THEN
				tr <= '0';
				x <= (OTHERS => '0');
			END IF;
			FOR i IN 1 TO 450 LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
				WAIT FOR 1 ns;
				IF NOT (is_on("6000----") OR is_on("55005400")) THEN
					errs := errs + 1;
					REPORT "trip flag and digits from different copies" SEVERITY ERROR;
				END IF;
			END LOOP;
		END LOOP;
		tr <= '1';
		x <= TO_SIGNED(-7730936, 32);                -- below xmin: the lowest shown is x
		xmin <= TO_SIGNED(-7659352, 32);
		show("59785978");
		IF lo /= TO_SIGNED(-7730936, 32) OR dd(31 DOWNTO 0) /= x"59785978" OR dt /= '1' OR db /= "00000" THEN
			errs := errs + 1;                        -- the copy for the VGA text: x itself, not xmin
			REPORT "exported copy wrong" SEVERITY ERROR;
		END IF;
		x <= (OTHERS => '0');                        -- old pair 6000 5900
		xmin <= TO_SIGNED(THR(0), 32);
		show("60005900");
		x <= TO_SIGNED(-7516193, 32);                -- new pair 5979 5978, both at once
		xmin <= TO_SIGNED(-7730936, 32);
		FOR i IN 1 TO 420 LOOP
			WAIT UNTIL clk = '1' AND clk'EVENT;
			WAIT FOR 1 ns;
			IF NOT (is_on("60005900") OR is_on("59795978")) THEN
				errs := errs + 1;
				REPORT "old and new digits mixed on the display" SEVERITY ERROR;
			END IF;
		END LOOP;
		show("59795978");
		x <= TO_SIGNED(1503238553, 32);
		xmin <= SHIFT_LEFT(TO_SIGNED(-1, 32), 31);
		show("Err 0000");
		pg <= '1';
		shed <= TO_SIGNED(AMT(0), 32);
		t <= 1234;
		show("04801234");
		shed <= TO_SIGNED(5 * AMT(0) + AMT(5), 32);
		t <= 9999;
		show("28009999");
		t <= 10000;
		shed <= TO_SIGNED(-AMT(0), 32);
		show("Err Err ");
		shed <= TO_SIGNED(5 * AMT(0) + AMT(5), 32);
		t <= 0;
		show("28000000");
		tr <= '0';
		show("2800----");
		n := 0;
		FOR i IN 1 TO 3000 LOOP
			IF i MOD 10 = 0 THEN
				x2 <= x2 - 100000;                   -- about 0.28 in the last digit each time
			END IF;
			WAIT UNTIL clk = '1' AND clk'EVENT;
			WAIT FOR 1 ns;
			now := h2(7) & h2(6) & h2(5) & h2(4);
			IF i > 1 AND now /= last THEN
				n := n + 1;
			END IF;
			last := now;
		END LOOP;
		IF n > 4 OR n = 0 THEN
			errs := errs + 1;
			REPORT "HEX7..4 changed " & INTEGER'IMAGE(n) & " times in 3 refresh periods" SEVERITY ERROR;
		END IF;

		pulse(load);                                 -- PK: before the trip 3.0 pu, not counted
		ir <= TO_SIGNED(805306368, 32);
		show("2800----");
		check(dt = '0', "trip flag shown before the trip");
		WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1';
		tr <= '1';                                   -- first trip step: 1.5 pu, then 1.0
		ir <= TO_SIGNED(402653184, 32);
		WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1';
		ir <= TO_SIGNED(268435456, 32);
		show("28000000");
		check(pkv = 1500 AND db(4) = '0', "PK " & INTEGER'IMAGE(pkv) & ", not 1500 (first trip step)");
		pulse(load);
		ir <= TO_SIGNED(2147483647, 32);             -- largest i1: clamped operand, 7.9999 pu
		show("28000000");
		check(pkv = 8000 AND db(4) = '0', "PK " & INTEGER'IMAGE(pkv) & ", not 8000 (clamped)");
		ir <= TO_SIGNED(2120640102, 32);             -- 7.9 + j7.9 = 11.17 pu
		ii <= TO_SIGNED(2120640102, 32);
		show("28000000");
		check(db(4) = '1', "PK above 9.999 not ERR");
		ir <= TO_SIGNED(268435456, 32);
		ii <= (OTHERS => '0');
		FOR i IN 1 TO 100 LOOP                       -- a load while a round runs
			WAIT UNTIL clk = '1' AND clk'EVENT;
		END LOOP;
		pulse(load);
		FOR i IN 1 TO 500 LOOP
			WAIT UNTIL clk = '1' AND clk'EVENT;
			WAIT FOR 1 ns;
			IF dt = '1' AND (db(4) = '1' OR pkv /= 1000) THEN
				errs := errs + 1;
				REPORT "PK from before the load shown" SEVERITY ERROR;
				EXIT;
			END IF;
		END LOOP;
		check(dt = '1' AND pkv = 1000, "PK " & INTEGER'IMAGE(pkv) & ", not 1000 after the load");
		ir <= TO_SIGNED(241591910, 32);              -- 0.9 - j0.8 once, then smaller for long
		ii <= TO_SIGNED(-214748364, 32);
		show("28000000");
		ir <= TO_SIGNED(268435456, 32);
		ii <= (OTHERS => '0');
		FOR i IN 1 TO 3 LOOP
			show("28000000");
		END LOOP;
		check(pkv = 1204, "PK " & INTEGER'IMAGE(pkv) & ", not kept at 1204");
		pulse(load);                                 -- operand rounded: 16392.5 / 16384 pu -> 16393 -> 1001
		ir <= TO_SIGNED(268574720, 32);              -- (truncated: 16392 -> 1000)
		show("28000000");
		check(pkv = 1001, "PK " & INTEGER'IMAGE(pkv) & ", not 1001 (rounded operand)");
		pulse(load);                                 -- i1 and t rise every step
		ramp <= TRUE;
		n := 0;
		FOR i IN 1 TO 2000 LOOP
			WAIT UNTIL clk = '1' AND clk'EVENT;
			WAIT FOR 1 ns;
			IF dt = '1' THEN
				sk := val(dd(63 DOWNTO 48));             -- shown t: the step of the copy
				a := (268435456 + 3000000 * sk + 8192) / 16384;
				IF pkv /= (4000 * a + 32768) / 65536 THEN
					errs := errs + 1;
					REPORT "PK " & INTEGER'IMAGE(pkv) & " not from the step of t = " & INTEGER'IMAGE(sk)
						SEVERITY ERROR;
					EXIT;
				END IF;
				n := n + 1;
			END IF;
		END LOOP;
		ramp <= FALSE;
		check(n > 1000, "ramp copies not shown");
		ASSERT errs = 0 REPORT "disp: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "disp: PASS, pages, rounding, out-of-range display, dashes, refresh and PK";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
