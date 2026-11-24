LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

-- Pause, single steps and slow motion: tick and run together, n3 = 20, a column of 8 steps.
--   1 step period 50, 200, 500, 5000 clocks for SW9:8 = 00, 01, 10, 11
--   2 paused: no step edge, the model holds at c = 45 with hl high
--   3 KEY2 in the middle of a column runs only the rest of it, at a column start the whole column
--   4 KEY3 runs exactly n3 steps; KEY2 or KEY3 pressed while a run is going is ignored
--   5 the run stops at once when the pause is switched off or a load comes
ENTITY run_tb IS
END run_tb;

ARCHITECTURE a OF run_tb IS
	SIGNAL clk, load, step, slow, go, hl, ce, ps, bz : STD_LOGIC := '0';
	SIGNAL key : STD_LOGIC_VECTOR(1 DOWNTO 0) := "11";
	SIGNAL sw : STD_LOGIC_VECTOR(2 DOWNTO 0) := "000";
	SIGNAL c : INTEGER RANGE 0 TO 49;
	SIGNAL sl : INTEGER RANGE 0 TO 3;
	SIGNAL n : INTEGER := 0;                                  -- step edges since the start
	SIGNAL done : BOOLEAN := FALSE;
BEGIN
	tk : ENTITY work.tick PORT MAP (clk, load, 0, c, step, slow, go, hl);
	rn : ENTITY work.run GENERIC MAP (20) PORT MAP (clk, load, step, ce, key, sw, go, ps, bz, sl);
	ce <= '1' WHEN n MOD 8 = 7 ELSE '0';

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
		IF clk = '1' AND clk'EVENT AND step = '1' THEN
			n <= n + 1;
		END IF;
	END PROCESS;

	PROCESS
		VARIABLE errs, k : INTEGER := 0;

		PROCEDURE check (ok : BOOLEAN; s : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT s SEVERITY ERROR;
			END IF;
		END check;

		PROCEDURE clocks (m : INTEGER) IS
		BEGIN
			FOR i IN 1 TO m LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
		END clocks;

		PROCEDURE press (i : INTEGER) IS
		BEGIN
			key(i) <= '0';
			clocks(20);
			key(i) <= '1';
			clocks(5);
		END press;

		PROCEDURE period (s : STD_LOGIC_VECTOR(1 DOWNTO 0); p : INTEGER) IS
			VARIABLE t : INTEGER := 0;
		BEGIN
			sw(2 DOWNTO 1) <= s;
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1';
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1';   -- the setting acts from this step on
			LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
				t := t + 1;
				EXIT WHEN step = '1';
			END LOOP;
			check(t = p, "step period " & INTEGER'IMAGE(t) & ", expected " & INTEGER'IMAGE(p));
		END period;

		PROCEDURE runs (i, steps : INTEGER; s : STRING) IS   -- press KEY i while paused, count the steps
		BEGIN
			k := n;
			press(i);
			WAIT UNTIL clk = '1' AND clk'EVENT AND bz = '0' FOR 100 us;
			clocks(300);
			check(n - k = steps, s & ": " & INTEGER'IMAGE(n - k) & " steps, expected " & INTEGER'IMAGE(steps));
			check(c = 45 AND hl = '1', s & ": not held at c = 45");
		END runs;
	BEGIN
		load <= '1';
		clocks(3);
		load <= '0';

		period("00", 50);                                   -- case 1
		period("01", 200);
		period("10", 500);
		period("11", 5000);
		check(sl = 3, "slow motion setting");
		period("00", 50);

		sw(0) <= '1';                                       -- case 2
		clocks(100);
		k := n;
		clocks(2000);
		check(n = k AND c = 45 AND hl = '1' AND ps = '1', "paused model moved or not held at c = 45");

		WAIT UNTIL clk = '1' AND clk'EVENT;                 -- case 3: n mod 8 is 3 or so, column ends at 7
		runs(0, 8 - n MOD 8, "KEY2 in a column");
		check(n MOD 8 = 0, "KEY2 did not stop at a column end");
		runs(0, 8, "KEY2 at a column start");

		runs(1, 20, "KEY3");                                -- case 4
		k := n;
		press(1);
		clocks(60);
		press(0);
		press(1);
		WAIT UNTIL clk = '1' AND clk'EVENT AND bz = '0' FOR 100 us;
		clocks(300);
		check(n - k = 20, "a press during a run changed it: " & INTEGER'IMAGE(n - k) & " steps");

		press(1);                                           -- case 5
		clocks(200);
		sw(0) <= '0';
		clocks(4);                                          -- two flip-flops, then bz
		check(bz = '0', "the run goes on after the pause is off");
		clocks(1000);
		sw(0) <= '1';
		clocks(100);
		press(1);
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		check(bz = '0', "the run goes on after a load");
		k := n;
		clocks(1000);
		check(n = k, "steps after the run was dropped");

		ASSERT errs = 0 REPORT "run: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "run: PASS, step periods, pause, KEY2 to the column end, KEY3 count, ignored presses, stop";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
