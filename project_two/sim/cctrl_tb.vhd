LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Checks controller block 4 (cctrl) against one vector window and its config file.
--   ks comes from the config file (at F 19; 0 when fb is off)
--   line k gives the filter states and the integrators uv, ui of step k; the _sig line k gives the
--   inputs from the other blocks and the expected dm, inc, v1. Each input is given only from the clock
--   cctrl needs it (wm1, uv1i 5, ir 11, xwi 13, xwr 14, uv1r 15, exc 23, il 27, cs and sn 30) and
--   bit-inverted before
--   every clock of step k: uv, ui equal line k; dm from c = 28, inc from 30, v1 from 33 to the end of the
--   step equal the _sig values
--   the run ends with every line read, exactly nsteps steps, the last state right, and no errors
ENTITY cctrl_tb IS
	GENERIC (fname : STRING := "vectors/held_fb_limit"; cname : STRING := "vectors/held_fb_config.txt";
		nsteps : INTEGER := 2048);
END cctrl_tb;

ARCHITECTURE a OF cctrl_tb IS
	SIGNAL clk, load, step, slow : STD_LOGIC := '0';
	SIGNAL k0 : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c  : INTEGER RANGE 0 TO 49;
	SIGNAL done, run : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;
	SIGNAL ks, cs, sn, dm : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL f : words(0 TO 7) := (OTHERS => (OTHERS => '0'));
	SIGNAL ir, il : words(0 TO 1) := (OTHERS => (OTHERS => '0'));
	SIGNAL s0, s, es : words(0 TO 3) := (OTHERS => (OTHERS => '0'));
	SIGNAL exc : SIGNED(32 DOWNTO 0) := (OTHERS => '0');
	SIGNAL wm1 : SIGNED(26 DOWNTO 0) := (OTHERS => '0');
	SIGNAL xwr, xwi : SIGNED(30 DOWNTO 0) := (OTHERS => '0');
	SIGNAL uv1r, uv1i : SIGNED(23 DOWNTO 0) := (OTHERS => '0');
	SIGNAL v1r, v1i : SIGNED(33 DOWNTO 0);
	SIGNAL inc : SIGNED(25 DOWNTO 0);
	SIGNAL e : sigs := (OTHERS => (OTHERS => '0'));
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow);
	dut : ENTITY work.cctrl PORT MAP (clk, load, step, c, ks, cs, sn, f, ir, il, exc, wm1, xwr, xwi, uv1r, uv1i,
		s0, s, v1r, v1i, dm, inc);

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
		IF run AND (s /= es OR (c >= 28 AND dm /= e(6)) OR (c >= 30 AND inc /= e(7))
			OR (c >= 33 AND (v1r /= e(0) OR v1i /= e(1)))) THEN
			cerr <= cerr + 1;
			REPORT "block 4 output or state wrong at c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
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

		PROCEDURE at (n : INTEGER) IS                -- wait for the edge that ends c = n - 1
		BEGIN
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = n - 1 FOR 51 * 20 ns;
		END at;
	BEGIN
		-- config: ks 17 and its F 40, method_fb 50
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

		readline(fv, l);
		rowread(l, k, r);
		k0 <= k MOD 1024;
		s0 <= (r(12), r(13), r(14), r(15));
		es <= (r(12), r(13), r(14), r(15));
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		run <= TRUE;
		WHILE NOT endfile(fv) LOOP
			f <= (r(6), r(7), r(8), r(9), r(10), r(11), r(16), r(17));
			readline(fs, l);
			sigread(l, v);
			e <= v;
			wm1 <= NOT RESIZE(v(16), 27);
			uv1i <= NOT RESIZE(v(20), 24);
			ir <= (NOT RESIZE(v(14), 32), NOT RESIZE(v(15), 32));
			xwi <= NOT RESIZE(v(18), 31);
			xwr <= NOT RESIZE(v(17), 31);
			uv1r <= NOT RESIZE(v(19), 24);
			exc <= NOT RESIZE(v(5), 33);
			il <= (NOT RESIZE(v(2), 32), NOT RESIZE(v(3), 32));
			cs <= NOT RESIZE(v(10), 18);
			sn <= NOT RESIZE(v(11), 18);
			readline(fv, l);
			rowread(l, kn, r);
			at(5);
			wm1 <= RESIZE(v(16), 27);
			uv1i <= RESIZE(v(20), 24);
			at(11);
			ir <= (RESIZE(v(14), 32), RESIZE(v(15), 32));
			at(13);
			xwi <= RESIZE(v(18), 31);
			at(14);
			xwr <= RESIZE(v(17), 31);
			at(15);
			uv1r <= RESIZE(v(19), 24);
			at(23);
			exc <= RESIZE(v(5), 33);
			at(27);
			il <= (RESIZE(v(2), 32), RESIZE(v(3), 32));
			at(30);
			cs <= RESIZE(v(10), 18);
			sn <= RESIZE(v(11), 18);
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 51 * 20 ns;
			IF step /= '1' THEN
				REPORT "timeout: no step pulse within 51 clocks" SEVERITY FAILURE;
			END IF;
			es <= (r(12), r(13), r(14), r(15));
			IF kn /= k + 1 THEN
				errs := errs + 1;
				REPORT "step " & INTEGER'IMAGE(k) & ": step number wrong" SEVERITY ERROR;
			END IF;
			k := kn;
			steps := steps + 1;
		END LOOP;
		run <= FALSE;
		WAIT FOR 1 ns;
		IF s /= es THEN
			errs := errs + 1;
			REPORT "last integrator state wrong" SEVERITY ERROR;
		END IF;
		errs := errs + cerr;
		ASSERT steps = nsteps AND errs = 0
			REPORT fname & ": FAIL, " & INTEGER'IMAGE(steps) & " steps, " & INTEGER'IMAGE(errs) & " errors"
			SEVERITY FAILURE;
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps, dm, inc, v1 and integrators match";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
