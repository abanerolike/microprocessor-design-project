LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Checks controller block 1 (meas) against one vector window and its config file.
--   first the filter constants in gfm_pkg must equal the config file
--   line k gives the plant states and the eight filter states of step k; the _sig line k gives the
--   inverter cos and sin, given only from the clock meas needs them (cs from c = 6, sn from 7) and
--   bit-inverted before
--   every clock of step k: the filter states equal line k (new values only after the edge that ends c = 49)
--   the run ends with every line read, exactly nsteps steps, the last state right, and no errors
ENTITY meas_tb IS
	GENERIC (fname : STRING := "vectors/held_fb_limit"; cname : STRING := "vectors/held_fb_config.txt";
		nsteps : INTEGER := 2048);
END meas_tb;

ARCHITECTURE a OF meas_tb IS
	SIGNAL clk, load, step, slow : STD_LOGIC := '0';
	SIGNAL k0 : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c  : INTEGER RANGE 0 TO 49;
	SIGNAL done, run : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;
	SIGNAL cs, sn : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL x : words(0 TO 5) := (OTHERS => (OTHERS => '0'));
	SIGNAL f0, f, ef : words(0 TO 7) := (OTHERS => (OTHERS => '0'));

	-- step number, plant states and filter states of one window line (words 0..5, 6..11, 16, 17)
	PROCEDURE row (l : INOUT LINE; k : OUT INTEGER; vx : OUT words; vf : OUT words) IS
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
	BEGIN
		read(l, k);
		FOR i IN 0 TO 17 LOOP
			hrd(l, w32);
			IF i < 6 THEN
				vx(i) := SIGNED(w32);
			ELSIF i < 12 THEN
				vf(i - 6) := SIGNED(w32);
			ELSIF i >= 16 THEN
				vf(i - 10) := SIGNED(w32);
			END IF;
		END LOOP;
	END row;
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow);
	dut : ENTITY work.meas PORT MAP (clk, load, step, c, x, cs, sn, f0, f);

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

	-- values seen at an edge are the ones held during the clock c that the edge ends
	PROCESS
	BEGIN
		WAIT UNTIL clk = '1' AND clk'EVENT;
		IF run AND f /= ef THEN
			cerr <= cerr + 1;
			REPORT "filter state wrong at c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
		END IF;
	END PROCESS;

	PROCESS
		TYPE table IS ARRAY (0 TO 80) OF SIGNED(47 DOWNTO 0);
		FILE fc : TEXT OPEN READ_MODE IS cname;
		FILE fv : TEXT OPEN READ_MODE IS fname & ".txt";
		FILE fs : TEXT OPEN READ_MODE IS fname & "_sig.txt";
		VARIABLE l : LINE;
		VARIABLE cf : table;
		VARIABLE k, kn, steps, errs : INTEGER := 0;
		VARIABLE vx : words(0 TO 5);
		VARIABLE vf : words(0 TO 7);
		VARIABLE vc, vs : SIGNED(17 DOWNTO 0);
		VARIABLE w48 : STD_LOGIC_VECTOR(47 DOWNTO 0);
		VARIABLE w34 : STD_LOGIC_VECTOR(33 DOWNTO 0);
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w26 : STD_LOGIC_VECTOR(25 DOWNTO 0);
		VARIABLE w25 : STD_LOGIC_VECTOR(24 DOWNTO 0);
		VARIABLE w18 : STD_LOGIC_VECTOR(17 DOWNTO 0);
		VARIABLE w2  : STD_LOGIC_VECTOR(1 DOWNTO 0);
	BEGIN
		-- config lines 0..22 are the constants (af1 0, af2 1), 23..45 their F
		FOR i IN cf'RANGE LOOP
			readline(fc, l);
			hrd(l, w48);
			cf(i) := SIGNED(w48);
		END LOOP;
		IF cf(0) /= AF1 OR cf(1) /= AF2 OR cf(23) /= FF1 OR cf(24) /= FF2 THEN
			errs := errs + 1;
			REPORT "filter constants differ from the config file" SEVERITY ERROR;
		END IF;

		readline(fv, l);
		row(l, k, vx, vf);
		k0 <= k MOD 1024;
		f0 <= vf;
		ef <= vf;
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		run <= TRUE;
		WHILE NOT endfile(fv) LOOP
			-- _sig line k: v1 x2, limited current x2, lim, exc, dm, inc, incg, pg, th_c, th_s, thg_c, thg_s
			readline(fs, l);
			hrd(l, w34);
			hrd(l, w34);
			hrd(l, w32);
			hrd(l, w32);
			hrd(l, w2);
			hrd(l, w34);
			hrd(l, w18);
			hrd(l, w26);
			hrd(l, w25);
			hrd(l, w18);
			hrd(l, w18);
			vc := SIGNED(w18);
			hrd(l, w18);
			vs := SIGNED(w18);
			x <= vx;
			readline(fv, l);
			row(l, kn, vx, vf);
			cs <= NOT vc;
			sn <= NOT vs;
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 5 FOR 51 * 20 ns;
			cs <= vc;
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 6 FOR 51 * 20 ns;
			sn <= vs;
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 51 * 20 ns;
			IF step /= '1' THEN
				REPORT "timeout: no step pulse within 51 clocks" SEVERITY FAILURE;
			END IF;
			ef <= vf;
			IF kn /= k + 1 THEN
				errs := errs + 1;
				REPORT "step " & INTEGER'IMAGE(k) & ": step number wrong" SEVERITY ERROR;
			END IF;
			k := kn;
			steps := steps + 1;
		END LOOP;
		run <= FALSE;
		WAIT FOR 1 ns;
		IF f /= ef THEN
			errs := errs + 1;
			REPORT "last filter state wrong" SEVERITY ERROR;
		END IF;
		errs := errs + cerr;
		ASSERT steps = nsteps AND errs = 0
			REPORT fname & ": FAIL, " & INTEGER'IMAGE(steps) & " steps, " & INTEGER'IMAGE(errs) & " errors"
			SEVERITY FAILURE;
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps, filter states match";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
