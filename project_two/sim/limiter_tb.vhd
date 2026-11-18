LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Checks controller block 3 (limiter) against one vector window and its config file.
--   first SEED_ROM in gfm_pkg must equal rom_seed.hex
--   Imax of step k is imax0 before k_short and imax_cont from then on; 2 pu or more means no limit
--   (en = 0, Imax taken as 1 pu). The threshold t2 = (Imax - Imax/2048)^2 is formed here, as the top level
--   will do. ir of step k comes from the _sig line, only from c = 11 (bit-inverted before)
--   every clock of step k, from the clock each output is promised (lim 14, exc 23, il re 26, il im 27) to
--   the end of the step, the output equals the _sig value
--   the run ends with every line read, exactly nsteps steps, and no errors
ENTITY limiter_tb IS
	GENERIC (fname : STRING := "vectors/held_fb_limit"; cname : STRING := "vectors/held_fb_config.txt";
		rom : STRING := "vectors/rom_seed.hex"; nsteps : INTEGER := 2048);
END limiter_tb;

ARCHITECTURE a OF limiter_tb IS
	CONSTANT ONE : SIGNED(31 DOWNTO 0) := SHIFT_LEFT(TO_SIGNED(1, 32), 28);
	SIGNAL clk, load, step, slow, en, lim : STD_LOGIC := '0';
	SIGNAL k0 : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c  : INTEGER RANGE 0 TO 49;
	SIGNAL done, run : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;
	SIGNAL imx : SIGNED(31 DOWNTO 0) := ONE;
	SIGNAL t2 : SIGNED(37 DOWNTO 0) := (OTHERS => '0');
	SIGNAL ir, il : words(0 TO 1) := (OTHERS => (OTHERS => '0'));
	SIGNAL exc : SIGNED(32 DOWNTO 0);
	SIGNAL e : sigs := (OTHERS => (OTHERS => '0'));
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow);
	dut : ENTITY work.limiter PORT MAP (clk, en, c, imx, t2, ir, il, lim, exc);

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
		IF run AND ((c >= 14 AND (lim = '1') /= (e(4) = 1)) OR (c >= 23 AND exc /= e(5))
			OR (c >= 26 AND il(0) /= e(2)) OR (c >= 27 AND il(1) /= e(3))) THEN
			cerr <= cerr + 1;
			REPORT "limiter output wrong at c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
		END IF;
	END PROCESS;

	PROCESS
		FILE fc : TEXT OPEN READ_MODE IS cname;
		FILE fv : TEXT OPEN READ_MODE IS fname & ".txt";
		FILE fs : TEXT OPEN READ_MODE IS fname & "_sig.txt";
		FILE fr : TEXT OPEN READ_MODE IS rom;
		VARIABLE l : LINE;
		VARIABLE cf : cfgs;
		VARIABLE r : row18;
		VARIABLE s : sigs;
		VARIABLE k, kn, steps, errs : INTEGER := 0;
		VARIABLE w18 : STD_LOGIC_VECTOR(17 DOWNTO 0);
		VARIABLE m, thr : SIGNED(31 DOWNTO 0);
		VARIABLE mm : SIGNED(47 DOWNTO 0);
	BEGIN
		FOR i IN 0 TO 191 LOOP
			readline(fr, l);
			hrd(l, w18);
			IF SEED_ROM(i) /= TO_INTEGER(UNSIGNED(w18)) THEN
				errs := errs + 1;
				REPORT "seed " & INTEGER'IMAGE(i) & " differs from rom_seed.hex" SEVERITY ERROR;
			END IF;
		END LOOP;
		-- config: imax0 55, imax_cont 56, k_short 58
		cfgread(fc, cf);

		readline(fv, l);
		rowread(l, k, r);
		k0 <= k MOD 1024;
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		run <= TRUE;
		WHILE NOT endfile(fv) LOOP
			mm := cf(55);
			IF k >= cf(58) THEN
				mm := cf(56);
			END IF;
			en <= '1';
			m := RESIZE(mm, 32);
			IF mm >= SHIFT_LEFT(TO_SIGNED(1, 48), 29) THEN
				en <= '0';
				m := ONE;
			END IF;
			thr := m - SHIFT_RIGHT(m, 11);
			imx <= m;
			t2 <= RESIZE(SHIFT_RIGHT(thr * thr, 28), 38);
			readline(fs, l);
			sigread(l, s);
			e <= s;
			ir <= (NOT RESIZE(s(14), 32), NOT RESIZE(s(15), 32));
			readline(fv, l);
			rowread(l, kn, r);
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 10 FOR 51 * 20 ns;
			ir <= (RESIZE(s(14), 32), RESIZE(s(15), 32));
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
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps, lim, exc and il match";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
