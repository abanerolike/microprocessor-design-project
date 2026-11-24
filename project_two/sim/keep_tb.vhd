LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- The kept copy of a run in disp. Every value follows the step count n, so its digits show which step
-- was copied: F and MIN 6000 - n, SHED n, T n, PK 1000 + n (x = -n/6000 pu, shed n/8000, i1 1 + n/1000).
-- A step every 5 clocks, a refresh every 100 clocks (a round is 80). ce is high during the step that
-- ends a column; the copy of that column must hold the values of the step after its edge (n = M + 1).
--   1 a written column is kept by the save: digits of M + 1, settings, ok; rdy is low from ce until the
--     column's round is done, the column is written only then
--   2 a run with no written column does not replace the kept copy
--   3 the kept copy is the last written column, not a later one still waiting
--   4 held model (fz = 1, no steps): refreshes go on, with the inputs of the last step edge even when
--     they have moved since (part of the next step already written); without fz they wait for an edge
--   5 held inside the last step of a column: the refreshes taken while held do not count as the column
--     copy; the column copy comes at the edge after the hold, with that edge's values
--   6 held, then a reset with no step after it: the refreshes show the start state (n = 0, no trip),
--     not the last edge of the run before
ENTITY keep_tb IS
END keep_tb;

ARCHITECTURE a OF keep_tb IS
	SIGNAL clk, load, step, tr, fz, ce, wr, sv, rdy, dt : STD_LOGIC := '0';
	SIGNAL ph : INTEGER RANGE 0 TO 4 := 0;
	SIGNAL n : INTEGER RANGE 0 TO 10000 := 0;
	SIGNAL runs, done : BOOLEAN := FALSE;
	SIGNAL m : INTEGER := -1;                                  -- ce during the step with n = m
	SIGNAL x, sh, ir, xo : SIGNED(31 DOWNTO 0);
	SIGNAL hex : segs;
	SIGNAL dd : STD_LOGIC_VECTOR(79 DOWNTO 0);
	SIGNAL db : STD_LOGIC_VECTOR(0 TO 4);
	SIGNAL lo : SIGNED(31 DOWNTO 0);
	SIGNAL set : STD_LOGIC_VECTOR(7 DOWNTO 0) := X"A5";
	SIGNAL pv : shown;
	SIGNAL ofs : BOOLEAN := FALSE;                             -- move x away from the step rule (case 4)
	SIGNAL zero : BOOLEAN := FALSE;                            -- a load restarts the model (case 6)
BEGIN
	dut : ENTITY work.disp GENERIC MAP (100) PORT MAP (clk, load, step, '0', tr, xo, xo, sh, ir, (OTHERS => '0'),
		n, hex, dd, db, dt, lo, fz, ce, wr, sv, set, rdy, pv);

	x <= -TO_SIGNED(n * 357913, 32);                         -- 2^31 / 6000 = 357913.9
	xo <= x - TO_SIGNED(357914 * 500, 32) WHEN ofs ELSE x;
	sh <= TO_SIGNED(n * 268435, 32) + 134217;                 -- 2^31 / 8000 = 268435.5
	ir <= TO_SIGNED(268435456 + n * 268435, 32);              -- 1 + n / 1000 pu, Q28
	ce <= '1' WHEN n = m ELSE '0';
	step <= '1' WHEN ph = 4 AND runs ELSE '0';
	tr <= '0' WHEN zero ELSE '1';

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

	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			ph <= (ph + 1) MOD 5;
			IF load = '1' AND zero THEN
				n <= 0;
			ELSIF step = '1' THEN
				n <= n + 1;
			END IF;
		END IF;
	END PROCESS;

	PROCESS
		VARIABLE errs : INTEGER := 0;
		VARIABLE low : BOOLEAN;
		VARIABLE k1 : INTEGER;

		PROCEDURE check (ok : BOOLEAN; s : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT s SEVERITY ERROR;
			END IF;
		END check;

		FUNCTION bcd (v : INTEGER) RETURN STD_LOGIC_VECTOR IS
		BEGIN
			RETURN STD_LOGIC_VECTOR(TO_UNSIGNED(v / 1000 MOD 10, 4) & TO_UNSIGNED(v / 100 MOD 10, 4)
				& TO_UNSIGNED(v / 10 MOD 10, 4) & TO_UNSIGNED(v MOD 10, 4));
		END bcd;

		PROCEDURE expect (k : INTEGER; s : STRING) IS     -- the kept copy shows step k
		BEGIN
			check(pv.ok = '1' AND pv.dt = '1' AND pv.st = X"A5", s & ": not kept");
			check(pv.dd = bcd(1000 + k) & bcd(k) & bcd(k) & bcd(6000 - k) & bcd(6000 - k), s & ": digits");
			check(pv.lo = -TO_SIGNED(k * 357913, 32), s & ": lowest x");
		END expect;

		PROCEDURE clocks (c : INTEGER) IS
		BEGIN
			FOR i IN 1 TO c LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
		END clocks;

		PROCEDURE column (write : BOOLEAN) IS              -- run past a column end 3 steps ahead, write it
			VARIABLE k : INTEGER;
		BEGIN
			k := n + 3;
			m <= k;
			WAIT UNTIL clk = '1' AND clk'EVENT AND n = k;
			WAIT FOR 1 ns;
			check(rdy = '0', "rdy high during the last step of a column");
			low := TRUE;
			WHILE low LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
				WAIT FOR 1 ns;
				low := rdy = '0';
			END LOOP;
			check(n >= k + 1 AND n <= k + 18, "column round too short or too long");
			IF write THEN
				wr <= '1';
				WAIT UNTIL clk = '1' AND clk'EVENT;
				wr <= '0';
			END IF;
		END column;

		PROCEDURE save IS                                   -- KEY0: save pulse on the first load clock
		BEGIN
			load <= '1';
			sv <= '1';
			WAIT UNTIL clk = '1' AND clk'EVENT;
			sv <= '0';
			clocks(3);
			load <= '0';
			WAIT FOR 1 ns;
		END save;
	BEGIN
		load <= '1';
		clocks(3);
		load <= '0';
		runs <= TRUE;
		check(pv.ok = '0', "a copy is kept before any save");

		column(TRUE);                                       -- case 1
		k1 := m + 1;
		clocks(300);
		save;
		expect(k1, "case 1");

		column(FALSE);                                      -- case 2: nothing written in this run
		save;
		expect(k1, "case 2");

		column(TRUE);                                       -- case 3
		k1 := m + 1;
		column(FALSE);
		save;
		expect(k1, "case 3");

		WAIT UNTIL dd'EVENT;                                -- case 4: stop 30 clocks after a refresh, so the
		clocks(30);                                         -- shown values are older than the last edge
		runs <= FALSE;
		clocks(10);
		k1 := n;
		ofs <= TRUE;                                        -- inputs move without an edge (shed at c = 12..18)
		clocks(400);
		check(dd(15 DOWNTO 0) /= bcd(6000 - k1), "a refresh without step edges while not held");
		fz <= '1';
		clocks(400);
		check(dd(15 DOWNTO 0) = bcd(6000 - k1), "held: the refresh does not show the last edge");
		fz <= '0';
		ofs <= FALSE;
		runs <= TRUE;
		clocks(400);

		m <= n + 2;                                         -- case 5: hold inside the column's last step
		WAIT UNTIL clk = '1' AND clk'EVENT AND ce = '1';
		clocks(2);
		runs <= FALSE;
		fz <= '1';
		clocks(500);
		check(rdy = '0', "a refresh while held took the column copy");
		fz <= '0';
		runs <= TRUE;
		WAIT UNTIL clk = '1' AND clk'EVENT AND rdy = '1';
		wr <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		wr <= '0';
		save;
		k1 := m + 1;
		expect(k1, "case 5");

		clocks(400);                                        -- case 6
		runs <= FALSE;
		fz <= '1';
		clocks(300);
		check(dd(15 DOWNTO 0) /= bcd(6000), "case 6: the run before already shows n = 0");
		zero <= TRUE;
		load <= '1';
		clocks(4);
		load <= '0';
		clocks(400);
		check(dd(63 DOWNTO 0) = bcd(0) & bcd(0) & bcd(6000) & bcd(6000) AND dt = '0',
			"held after a reset: the refresh shows the run before, not the start state");

		ASSERT errs = 0 REPORT "keep: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "keep: PASS, column copy, save, empty run, last written column, refresh while held, reset while held";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
