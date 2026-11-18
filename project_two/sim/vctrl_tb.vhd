LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Checks controller block 2 (vctrl) against one vector window and its config file.
--   first the droop and PI constants in gfm_pkg must equal the config file
--   line k gives the filter and integrator states of step k (held for the whole step); the _sig line k
--   gives the expected ir, wm1, xw, uv1
--   every clock of step k, from the clock each output is promised (wm1 2, uv1i 4, ir 10, xwi 13, xwr 14,
--   uv1r 15) to the end of the step, the output equals the _sig value
--   the run ends with every line read, exactly nsteps steps, and no errors
ENTITY vctrl_tb IS
	GENERIC (fname : STRING := "vectors/held_fb_limit"; cname : STRING := "vectors/held_fb_config.txt";
		nsteps : INTEGER := 2048);
END vctrl_tb;

ARCHITECTURE a OF vctrl_tb IS
	SIGNAL clk, load, step, slow : STD_LOGIC := '0';
	SIGNAL k0 : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c  : INTEGER RANGE 0 TO 49;
	SIGNAL done, run : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;
	SIGNAL p0 : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL f  : words(0 TO 7) := (OTHERS => (OTHERS => '0'));
	SIGNAL uv, ir : words(0 TO 1) := (OTHERS => (OTHERS => '0'));
	SIGNAL wm1 : SIGNED(26 DOWNTO 0);
	SIGNAL xwr, xwi : SIGNED(30 DOWNTO 0);
	SIGNAL uv1r, uv1i : SIGNED(23 DOWNTO 0);
	SIGNAL e : sigs := (OTHERS => (OTHERS => '0'));
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow);
	dut : ENTITY work.vctrl PORT MAP (clk, c, p0, f, uv, ir, wm1, xwr, xwi, uv1r, uv1i);

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
		IF run AND ((c >= 2 AND wm1 /= e(16)) OR (c >= 4 AND uv1i /= e(20)) OR (c >= 10 AND (ir(0) /= e(14)
			OR ir(1) /= e(15))) OR (c >= 13 AND xwi /= e(18)) OR (c >= 14 AND xwr /= e(17))
			OR (c >= 15 AND uv1r /= e(19))) THEN
			cerr <= cerr + 1;
			REPORT "block 2 output wrong at c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
		END IF;
	END PROCESS;

	PROCESS
		FILE fc : TEXT OPEN READ_MODE IS cname;
		FILE fv : TEXT OPEN READ_MODE IS fname & ".txt";
		FILE fs : TEXT OPEN READ_MODE IS fname & "_sig.txt";
		VARIABLE l : LINE;
		VARIABLE cf : cfgs;
		VARIABLE r : row18;
		VARIABLE s : sigs;
		VARIABLE k, kn, steps, errs : INTEGER := 0;
	BEGIN
		-- config: constants 0..22, their F 23..45 (dp 10, dq 11, kpv 8, tkiv 3), p0 at 52
		cfgread(fc, cf);
		IF cf(10) /= KDP OR cf(11) /= KDQ OR cf(8) /= KPV OR cf(3) /= KIV OR cf(4) /= KAW OR cf(9) /= KPI
			OR cf(2) /= KII OR cf(33) /= FDP OR cf(34) /= FDQ OR cf(31) /= FPV OR cf(26) /= FIV
			OR cf(27) /= FAW OR cf(32) /= FPI OR cf(25) /= FII THEN
			errs := errs + 1;
			REPORT "controller constants differ from the config file" SEVERITY ERROR;
		END IF;
		p0 <= RESIZE(cf(52), 32);

		readline(fv, l);
		rowread(l, k, r);
		k0 <= k MOD 1024;
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		run <= TRUE;
		WHILE NOT endfile(fv) LOOP
			f <= (r(6), r(7), r(8), r(9), r(10), r(11), r(16), r(17));
			uv <= (r(12), r(13));
			readline(fs, l);
			sigread(l, s);
			e <= s;
			readline(fv, l);
			rowread(l, kn, r);
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 51 * 20 ns;
			IF step /= '1' THEN
				REPORT "timeout: no step pulse within 51 clocks" SEVERITY FAILURE;
			END IF;
			IF kn /= k + 1 THEN
				errs := errs + 1;
				REPORT "step " & INTEGER'IMAGE(k) & ": step number wrong" SEVERITY ERROR;
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
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps, ir, wm1, xw and uv1 match";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
