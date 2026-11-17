LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;

-- Checks two nco copies (inverter angle th, grid angle thg) against one vector window.
-- Line k of the window gives both phases at the start of step k; line k of the _sig file gives the two
-- phase steps of step k and the sin and cos of the step-k phases.
--   first every table entry: with phase i * 2^30 (no fraction) sn = rom(i) and cs = rom(i + 256)
--   every clock of step k: both phases equal line k (so a new phase must appear right after the edge that
--   ends c = 49, and not earlier), sn equals the step-k value from c = 2 and cs from c = 3
--   the phase steps are given only from the clock the step schedule makes them ready (inc from c = 26,
--   incg from c = 2) and the bit-inverted value before that, so an nco that takes them early fails
--   the run ends with every line read, exactly nsteps steps, the last new phase right, and no errors
ENTITY nco_tb IS
	GENERIC (fname : STRING := "vectors/held_fb_trip"; rom : STRING := "vectors/rom_sin.hex";
		nsteps : INTEGER := 2048);
END nco_tb;

ARCHITECTURE a OF nco_tb IS
	SIGNAL clk, load, step, slow : STD_LOGIC := '0';
	SIGNAL k0 : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c  : INTEGER RANGE 0 TO 49;
	SIGNAL done, run : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;
	SIGNAL p0, q0, p, q, ep, eq : UNSIGNED(39 DOWNTO 0) := (OTHERS => '0');
	SIGNAL ip, iq : SIGNED(25 DOWNTO 0) := (OTHERS => '0');
	SIGNAL cp, sp, cq, sq, ecp, esp, ecq, esq : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	TYPE table IS ARRAY (0 TO 1023) OF SIGNED(17 DOWNTO 0);
	CONSTANT ci : INTEGER := 26;
	CONSTANT cg : INTEGER := 2;

	-- step number and the two phases of one window line; the 18 words before them are skipped
	PROCEDURE row (l : INOUT LINE; k : OUT INTEGER; th, thg : OUT UNSIGNED) IS
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w40 : STD_LOGIC_VECTOR(39 DOWNTO 0);
	BEGIN
		read(l, k);
		FOR i IN 1 TO 18 LOOP
			hrd(l, w32);
		END LOOP;
		hrd(l, w40);
		th := UNSIGNED(w40);
		hrd(l, w40);
		thg := UNSIGNED(w40);
	END row;
BEGIN
	tk : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow);
	np : ENTITY work.nco PORT MAP (clk, load, step, c, p0, ip, p, cp, sp);
	nq : ENTITY work.nco PORT MAP (clk, load, step, c, q0, iq, q, cq, sq);

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
		IF run AND (p /= ep OR q /= eq OR (c >= 2 AND (sp /= esp OR sq /= esq)) OR (c >= 3 AND (cp /= ecp OR cq /= ecq))) THEN
			cerr <= cerr + 1;
			REPORT "phase, sin or cos wrong at c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
		END IF;
	END PROCESS;

	PROCESS
		FILE fv : TEXT OPEN READ_MODE IS fname & ".txt";
		FILE fs : TEXT OPEN READ_MODE IS fname & "_sig.txt";
		FILE fr : TEXT OPEN READ_MODE IS rom;
		VARIABLE t : table;
		VARIABLE l : LINE;
		VARIABLE k, kn, steps, errs : INTEGER := 0;
		VARIABLE th, thg : UNSIGNED(39 DOWNTO 0);
		VARIABLE vi, vg : SIGNED(25 DOWNTO 0);
		VARIABLE w34 : STD_LOGIC_VECTOR(33 DOWNTO 0);
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w26 : STD_LOGIC_VECTOR(25 DOWNTO 0);
		VARIABLE w25 : STD_LOGIC_VECTOR(24 DOWNTO 0);
		VARIABLE w18 : STD_LOGIC_VECTOR(17 DOWNTO 0);
		VARIABLE w2  : STD_LOGIC_VECTOR(1 DOWNTO 0);
	BEGIN
		FOR i IN 0 TO 1023 LOOP
			readline(fr, l);
			hrd(l, w18);
			t(i) := SIGNED(w18);
		END LOOP;
		FOR i IN 0 TO 1023 LOOP
			p0 <= TO_UNSIGNED(i, 10) & TO_UNSIGNED(0, 30);
			load <= '1';
			WAIT UNTIL clk = '1' AND clk'EVENT;
			load <= '0';
			FOR j IN 1 TO 3 LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
			WAIT FOR 1 ns;
			IF sp /= t(i) OR cp /= t((i + 256) MOD 1024) THEN
				errs := errs + 1;
				REPORT "table entry " & INTEGER'IMAGE(i) & " wrong" SEVERITY ERROR;
			END IF;
		END LOOP;
		readline(fv, l);
		row(l, k, th, thg);
		k0 <= k MOD 1024;
		p0 <= th;
		q0 <= thg;
		ep <= th;
		eq <= thg;
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
			vi := SIGNED(w26);
			hrd(l, w25);
			vg := RESIZE(SIGNED(w25), 26);
			hrd(l, w18);
			hrd(l, w18);
			ecp <= SIGNED(w18);
			hrd(l, w18);
			esp <= SIGNED(w18);
			hrd(l, w18);
			ecq <= SIGNED(w18);
			hrd(l, w18);
			esq <= SIGNED(w18);
			readline(fv, l);
			row(l, kn, th, thg);
			ip <= NOT vi;
			iq <= NOT vg;
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = cg - 1 FOR 51 * 20 ns;
			iq <= vg;
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = ci - 1 FOR 51 * 20 ns;
			ip <= vi;
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 51 * 20 ns;
			IF step /= '1' THEN
				REPORT "timeout: no step pulse within 51 clocks" SEVERITY FAILURE;
			END IF;
			ep <= th;
			eq <= thg;
			IF kn /= k + 1 THEN
				errs := errs + 1;
				REPORT "step " & INTEGER'IMAGE(k) & ": step number wrong" SEVERITY ERROR;
			END IF;
			k := kn;
			steps := steps + 1;
		END LOOP;
		run <= FALSE;
		WAIT FOR 1 ns;
		IF p /= ep OR q /= eq THEN
			errs := errs + 1;
			REPORT "last new phase wrong" SEVERITY ERROR;
		END IF;
		errs := errs + cerr;
		ASSERT steps = nsteps AND errs = 0
			REPORT fname & ": FAIL, " & INTEGER'IMAGE(steps) & " steps, " & INTEGER'IMAGE(errs) & " errors"
			SEVERITY FAILURE;
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps and 1024 table entries match";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
