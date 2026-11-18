LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Checks the whole controller (four blocks wired together) against one vector window and its config file.
--   from the config file: p0, ks (0 when fb is off); Imax of step k (imax0 before k_short, imax_cont after; 2 pu or more
--   means no limit) and the threshold t2 formed as the top level will do
--   line k gives the plant states (held for the step) and the twelve controller states; the inverter sin
--   and cos come from the _sig line as the NCO gives them (sn from c = 2, cs from 3, bit-inverted before)
--   every clock of step k: the twelve states equal line k; lim from c = 14, exc from 23, il re from 26
--   and im from 27, dm from 28, inc from 30, v1 from 33 to the end of the step equal the _sig values
--   the run ends with every line read, exactly nsteps steps, the last state right, and no errors
ENTITY controller_tb IS
	GENERIC (fname : STRING := "vectors/held_fb_limit"; cname : STRING := "vectors/held_fb_config.txt";
		nsteps : INTEGER := 2048);
END controller_tb;

ARCHITECTURE a OF controller_tb IS
	CONSTANT ONE : SIGNED(31 DOWNTO 0) := SHIFT_LEFT(TO_SIGNED(1, 32), 28);
	SIGNAL clk, load, step, slow, en, lim : STD_LOGIC := '0';
	SIGNAL k0 : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c  : INTEGER RANGE 0 TO 49;
	SIGNAL done, run : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;
	SIGNAL x : words(0 TO 5) := (OTHERS => (OTHERS => '0'));
	SIGNAL cs, sn, ks, dm : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL p0, imx : SIGNED(31 DOWNTO 0) := ONE;
	SIGNAL t2 : SIGNED(37 DOWNTO 0) := (OTHERS => '0');
	SIGNAL f0, f, ef : words(0 TO 7) := (OTHERS => (OTHERS => '0'));
	SIGNAL s0, s, es : words(0 TO 3) := (OTHERS => (OTHERS => '0'));
	SIGNAL il : words(0 TO 1);
	SIGNAL exc : SIGNED(32 DOWNTO 0);
	SIGNAL v1r, v1i : SIGNED(33 DOWNTO 0);
	SIGNAL inc : SIGNED(25 DOWNTO 0);
	SIGNAL e : sigs := (OTHERS => (OTHERS => '0'));
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow);
	dut : ENTITY work.controller PORT MAP (clk, load, step, en, c, x, cs, sn, p0, imx, t2, ks, f0, s0, f, s, il, lim,
		exc, dm, v1r, v1i, inc);

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
		IF run AND (f /= ef OR s /= es OR (c >= 14 AND (lim = '1') /= (e(4) = 1)) OR (c >= 23 AND exc /= e(5))
			OR (c >= 26 AND il(0) /= e(2)) OR (c >= 27 AND il(1) /= e(3)) OR (c >= 28 AND dm /= e(6))
			OR (c >= 30 AND inc /= e(7)) OR (c >= 33 AND (v1r /= e(0) OR v1i /= e(1)))) THEN
			cerr <= cerr + 1;
			REPORT "controller output or state wrong at c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
		END IF;
	END PROCESS;

	PROCESS
		FILE fc : TEXT OPEN READ_MODE IS cname;
		FILE fv : TEXT OPEN READ_MODE IS fname & ".txt";
		FILE fs : TEXT OPEN READ_MODE IS fname & "_sig.txt";
		VARIABLE l : LINE;
		VARIABLE cf : cfgs;
		VARIABLE r : row18;
		VARIABLE v : sigs;
		VARIABLE k, kn, steps, errs : INTEGER := 0;
		VARIABLE m, thr : SIGNED(31 DOWNTO 0);
		VARIABLE mm : SIGNED(47 DOWNTO 0);
	BEGIN
		-- config: ks 17 (F 40), method_fb 50, p0 52, imax0 55, imax_cont 56, k_short 58
		cfgread(fc, cf);
		IF cf(17) /= 0 AND cf(40) /= FKS THEN
			errs := errs + 1;
			REPORT "ks is not at F 19" SEVERITY ERROR;
		END IF;
		IF cf(50) = 0 AND cf(17) /= 0 THEN
			errs := errs + 1;
			REPORT "fb is off but ks is not 0" SEVERITY ERROR;
		END IF;
		ks <= RESIZE(cf(17), 18);
		p0 <= RESIZE(cf(52), 32);

		readline(fv, l);
		rowread(l, k, r);
		k0 <= k MOD 1024;
		f0 <= (r(6), r(7), r(8), r(9), r(10), r(11), r(16), r(17));
		s0 <= (r(12), r(13), r(14), r(15));
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		run <= TRUE;
		WHILE NOT endfile(fv) LOOP
			x <= (r(0), r(1), r(2), r(3), r(4), r(5));
			ef <= (r(6), r(7), r(8), r(9), r(10), r(11), r(16), r(17));
			es <= (r(12), r(13), r(14), r(15));
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
			sigread(l, v);
			e <= v;
			cs <= NOT RESIZE(v(10), 18);
			sn <= NOT RESIZE(v(11), 18);
			readline(fv, l);
			rowread(l, kn, r);
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 1 FOR 51 * 20 ns;
			sn <= RESIZE(v(11), 18);
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 2 FOR 51 * 20 ns;
			cs <= RESIZE(v(10), 18);
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
		WAIT FOR 1 ns;
		ef <= (r(6), r(7), r(8), r(9), r(10), r(11), r(16), r(17));
		es <= (r(12), r(13), r(14), r(15));
		run <= FALSE;
		WAIT FOR 1 ns;
		IF f /= ef OR s /= es THEN
			errs := errs + 1;
			REPORT "last controller state wrong" SEVERITY ERROR;
		END IF;
		errs := errs + cerr;
		ASSERT steps = nsteps AND errs = 0
			REPORT fname & ": FAIL, " & INTEGER'IMAGE(steps) & " steps, " & INTEGER'IMAGE(errs) & " errors"
			SEVERITY FAILURE;
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps, controller states and outputs match";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
