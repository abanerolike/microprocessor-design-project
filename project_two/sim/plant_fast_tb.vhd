LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Checks plant_fast against one vector window and its config file.
--   first the LCL constants and their F in gfm_pkg must equal the config file
--   line k gives i1, vc, i2 at the start of step k; the _sig line k gives v1, pg and the grid sin and cos.
--   Each input is given only from the clock it is ready in the step schedule (sg from c = 2, cg from 3,
--   v1 from 29) and bit-inverted before, so a module that reads one early fails
--   every clock of step k: the six states equal line k (new values only after the edge that ends c = 49),
--   pg equals the _sig value from c = 6
--   the run ends with every line read, exactly nsteps steps, the last state right, and no errors
ENTITY plant_fast_tb IS
	GENERIC (fname : STRING := "vectors/held_fb_limit"; cname : STRING := "vectors/held_fb_config.txt";
		nsteps : INTEGER := 2048);
END plant_fast_tb;

ARCHITECTURE a OF plant_fast_tb IS
	TYPE words IS ARRAY (0 TO 5) OF SIGNED(31 DOWNTO 0);
	SIGNAL clk, load, step, slow : STD_LOGIC := '0';
	SIGNAL k0 : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c  : INTEGER RANGE 0 TO 49;
	SIGNAL done, run : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;
	SIGNAL v1r, v1i : SIGNED(33 DOWNTO 0) := (OTHERS => '0');
	SIGNAL cg, sg, pg, epg : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL s0, s, es : words := (OTHERS => (OTHERS => '0'));

	-- step number and the six LCL words of one window line; the rest of the line is not needed
	PROCEDURE row (l : INOUT LINE; k : OUT INTEGER; v : OUT words) IS
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
	BEGIN
		read(l, k);
		FOR i IN 0 TO 5 LOOP
			hrd(l, w32);
			v(i) := SIGNED(w32);
		END LOOP;
	END row;
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow);
	dut : ENTITY work.plant_fast PORT MAP (clk, load, step, c, v1r, v1i, cg, sg, s0(0), s0(1), s0(2), s0(3), s0(4), s0(5),
		s(0), s(1), s(2), s(3), s(4), s(5), pg);

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
		IF run AND (s /= es OR (c >= 6 AND pg /= epg)) THEN
			cerr <= cerr + 1;
			REPORT "LCL state or pg wrong at c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
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
		VARIABLE v : words;
		VARIABLE vr, vi : SIGNED(33 DOWNTO 0);
		VARIABLE vc, vs : SIGNED(17 DOWNTO 0);
		VARIABLE w48 : STD_LOGIC_VECTOR(47 DOWNTO 0);
		VARIABLE w34 : STD_LOGIC_VECTOR(33 DOWNTO 0);
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w26 : STD_LOGIC_VECTOR(25 DOWNTO 0);
		VARIABLE w25 : STD_LOGIC_VECTOR(24 DOWNTO 0);
		VARIABLE w18 : STD_LOGIC_VECTOR(17 DOWNTO 0);
		VARIABLE w2  : STD_LOGIC_VECTOR(1 DOWNTO 0);
	BEGIN
		-- config lines 0..22 are the constants, 23..45 their F (a1 5, ac 6, a2 7, bc 12, xl1 13, r1 14,
		-- xl2t 15, r2t 16)
		FOR i IN cf'RANGE LOOP
			readline(fc, l);
			hrd(l, w48);
			cf(i) := SIGNED(w48);
		END LOOP;
		IF cf(5) /= A1 OR cf(6) /= AC OR cf(7) /= A2 OR cf(12) /= BC OR cf(13) /= XL1 OR cf(14) /= R1
			OR cf(15) /= XL2 OR cf(16) /= R2 OR cf(28) /= FA1 OR cf(29) /= FAC OR cf(30) /= FA2 OR cf(35) /= FBC
			OR cf(36) /= FX1 OR cf(37) /= FR1 OR cf(38) /= FX2 OR cf(39) /= FR2 THEN
			errs := errs + 1;
			REPORT "LCL constants differ from the config file" SEVERITY ERROR;
		END IF;

		readline(fv, l);
		row(l, k, v);
		k0 <= k MOD 1024;
		s0 <= v;
		es <= v;
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		run <= TRUE;
		WHILE NOT endfile(fv) LOOP
			-- _sig line k: v1 x2, limited current x2, lim, exc, dm, inc, incg, pg, th_c, th_s, thg_c, thg_s
			readline(fs, l);
			hrd(l, w34);
			vr := SIGNED(w34);
			hrd(l, w34);
			vi := SIGNED(w34);
			hrd(l, w32);
			hrd(l, w32);
			hrd(l, w2);
			hrd(l, w34);
			hrd(l, w18);
			hrd(l, w26);
			hrd(l, w25);
			hrd(l, w18);
			epg <= SIGNED(w18);
			hrd(l, w18);
			hrd(l, w18);
			hrd(l, w18);
			vc := SIGNED(w18);
			hrd(l, w18);
			vs := SIGNED(w18);
			readline(fv, l);
			row(l, kn, v);
			v1r <= NOT vr;
			v1i <= NOT vi;
			cg <= NOT vc;
			sg <= NOT vs;
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 1 FOR 51 * 20 ns;
			sg <= vs;
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 2 FOR 51 * 20 ns;
			cg <= vc;
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 28 FOR 51 * 20 ns;
			v1r <= vr;
			v1i <= vi;
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 51 * 20 ns;
			IF step /= '1' THEN
				REPORT "timeout: no step pulse within 51 clocks" SEVERITY FAILURE;
			END IF;
			es <= v;
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
			REPORT "last LCL state wrong" SEVERITY ERROR;
		END IF;
		errs := errs + cerr;
		ASSERT steps = nsteps AND errs = 0
			REPORT fname & ": FAIL, " & INTEGER'IMAGE(steps) & " steps, " & INTEGER'IMAGE(errs) & " errors"
			SEVERITY FAILURE;
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps, LCL states and pg match";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
