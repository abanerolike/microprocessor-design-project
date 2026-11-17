LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Boundary cases of one grid update that the vector windows cannot pin down. Each case loads a state
-- at step position 1023, so the first step is an update, and checks the result after its last edge.
-- With pg = pg0 = psum = shed = dp = 0, dx = pm - D x; pm = 2x + d makes dx = d (D = 2).
--   A: x on the 59.0 Hz threshold and dx = 0, so the new x equals it: not below, counters reset
--   B: x one above and dx = -12890, so the new x is one below: stages 0 and 6 count (old x would not)
--   C: x one below and dx = +12890, so the new x is one above: counters reset (old x would count)
--   D: pm at the reserve cap with x = 0, so the governor falls: pm must move down, not hold
ENTITY plant_slow_edge_tb IS
END plant_slow_edge_tb;

ARCHITECTURE a OF plant_slow_edge_tb IS
	CONSTANT CAP0 : SIGNED(31 DOWNTO 0) := TO_SIGNED(26843546, 32);
	SIGNAL clk, load, step, slow : STD_LOGIC := '0';
	SIGNAL c : INTEGER RANGE 0 TO 49;
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL zero18 : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL zero32, x0, pm0, x, pm, shed : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL zero28, psum : SIGNED(27 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tk0 : counts := (OTHERS => 5);
	SIGNAL ticks : counts;
	SIGNAL ar0 : STD_LOGIC_VECTOR(0 TO 6) := (OTHERS => '1');
	SIGNAL armed : STD_LOGIC_VECTOR(0 TO 6);
	SIGNAL incg : SIGNED(24 DOWNTO 0);
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, 1023, c, step, slow);
	dut : ENTITY work.plant_slow PORT MAP (clk, load, step, slow, c, zero18, zero18, zero32, CAP0, x0, pm0, zero32,
		zero28, tk0, ar0, x, pm, shed, psum, ticks, armed, incg);

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
		VARIABLE errs : INTEGER := 0;

		PROCEDURE update (xs, ps : SIGNED(31 DOWNTO 0)) IS
		BEGIN
			x0 <= xs;
			pm0 <= ps;
			load <= '1';
			WAIT UNTIL clk = '1' AND clk'EVENT;
			load <= '0';
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1';
			WAIT FOR 1 ns;
		END update;

		PROCEDURE check (ok : BOOLEAN; name : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT "case " & name & " wrong" SEVERITY ERROR;
			END IF;
		END check;

		CONSTANT T : SIGNED(31 DOWNTO 0) := TO_SIGNED(THR(0), 32);
		CONSTANT A : counts := (OTHERS => 0);
		CONSTANT B : counts := (6, 0, 0, 0, 0, 0, 6);
	BEGIN
		update(T, T + T);
		check(x = T AND ticks = A, "A, new x on the threshold");
		update(T + 1, T + T + 2 - 12890);
		check(x = T - 1 AND ticks = B, "B, new x just below");
		update(T - 1, T + T - 2 + 12890);
		check(x = T + 1 AND ticks = A, "C, new x just above");
		update(zero32, CAP0);
		check(pm = CAP0 + RESIZE(rs(RESIZE(-CAP0, 36) * TO_SIGNED(GT, 18), FGT), 32), "D, governor falls at the cap");
		ASSERT errs = 0 REPORT "plant_slow edges: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "plant_slow edges: PASS, 4 cases";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
