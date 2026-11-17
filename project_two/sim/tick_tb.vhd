LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;

-- Checks tick against one vector window.
-- At every rising edge the testbench reads c, step and slow as they were before the edge, that is the
-- control signals of the clock that the edge ends; the state registers of the model are written at the
-- edge that ends c = 49.
--   every clock: c counts 0 to 49 from the load, and step is 1 exactly at c = 49
--   every step k: slow = (k mod 1024 = 1023); on those steps the power sum on line k+1 must be 0
--   the run ends with every line read, exactly nsteps steps, and no errors; a stuck counter hits the timeout
ENTITY tick_tb IS
	GENERIC (fname : STRING := "vectors/held_fb_trip.txt"; nsteps : INTEGER := 2048);
END tick_tb;

ARCHITECTURE a OF tick_tb IS
	SIGNAL clk, load, step, slow : STD_LOGIC := '0';
	SIGNAL k0   : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c    : INTEGER RANGE 0 TO 49;
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL run  : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;

	-- step number and power sum of one line; the 22 state words before the sum are skipped
	PROCEDURE row (l : INOUT LINE; k : OUT INTEGER; psum : OUT INTEGER) IS
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w40 : STD_LOGIC_VECTOR(39 DOWNTO 0);
		VARIABLE w28 : STD_LOGIC_VECTOR(27 DOWNTO 0);
	BEGIN
		read(l, k);
		FOR i IN 1 TO 18 LOOP
			hrd(l, w32);
		END LOOP;
		hrd(l, w40);
		hrd(l, w40);
		hrd(l, w32);
		hrd(l, w32);
		hrd(l, w28);
		psum := to_integer(signed(w28));
	END row;
BEGIN
	dut : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow);

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

	-- clock-by-clock check of the 50-clock step
	PROCESS
		VARIABLE n : INTEGER := 0;
	BEGIN
		WAIT UNTIL clk = '1' AND clk'EVENT;
		IF run THEN
			IF c /= n OR (step = '1') /= (n = 49) THEN
				cerr <= cerr + 1;
				REPORT "clock " & INTEGER'IMAGE(n) & " of the step: c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
			END IF;
			n := (n + 1) MOD 50;
		END IF;
	END PROCESS;

	PROCESS
		FILE f : TEXT OPEN READ_MODE IS fname;
		VARIABLE l : LINE;
		VARIABLE k, kn, psum, steps, slows, errs : INTEGER := 0;
	BEGIN
		readline(f, l);
		row(l, k, psum);
		k0 <= k MOD 1024;
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		run <= TRUE;
		WHILE NOT endfile(f) LOOP
			readline(f, l);
			row(l, kn, psum);
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 51 * 20 ns;
			IF step /= '1' THEN
				REPORT "timeout: no step pulse within 51 clocks" SEVERITY FAILURE;
			END IF;
			IF (slow = '1') /= (k MOD 1024 = 1023) OR (slow = '1' AND psum /= 0) OR kn /= k + 1 THEN
				errs := errs + 1;
				REPORT "step " & INTEGER'IMAGE(k) & ": slow flag or step number wrong" SEVERITY ERROR;
			END IF;
			IF slow = '1' THEN
				slows := slows + 1;
			END IF;
			k := kn;
			steps := steps + 1;
		END LOOP;
		run <= FALSE;
		WAIT FOR 1 ns;
		errs := errs + cerr;
		ASSERT steps = nsteps AND errs = 0
			REPORT fname & ": FAIL, " & INTEGER'IMAGE(steps) & " steps, " & INTEGER'IMAGE(errs) & " errors"
			SEVERITY FAILURE;
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps, " & INTEGER'IMAGE(slows) & " grid updates";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
