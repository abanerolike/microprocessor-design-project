LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Checks plant_slow against one vector window and its config file.
--   first the grid gains, their F and the UFLS table in gfm_pkg must equal the config file
--   line k gives x, pm, psum, shed, ticks and armed at the start of step k; the _sig line k gives incg
--   and the grid power sample pg of step k. pg is given from c = 7 only (bit-inverted before), the lost
--   generation is the config trip size from step k_trip on
--   every clock of step k: x, pm and psum equal line k; shed, ticks and armed equal line k up to c = 12
--   and line k+1 from c = 19; incg equals the _sig value from c = 2
--   the run ends with every line read, exactly nsteps steps, the last state right, and no errors
ENTITY plant_slow_tb IS
	GENERIC (fname : STRING := "vectors/held_sat_ufls"; cname : STRING := "vectors/held_sat_config.txt";
		nsteps : INTEGER := 2048);
END plant_slow_tb;

ARCHITECTURE a OF plant_slow_tb IS
	SIGNAL clk, load, step, slow : STD_LOGIC := '0';
	SIGNAL k0 : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c  : INTEGER RANGE 0 TO 49;
	SIGNAL done, run : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;
	SIGNAL pg, pg0 : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL dp, cap, x0, pm0, sh0, x, pm, shed, ex, epm, esh, nsh : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL ps0, psum, eps : SIGNED(27 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tk0, ticks, etk, ntk : counts := (OTHERS => 0);
	SIGNAL ar0, armed, ear, nar : STD_LOGIC_VECTOR(0 TO 6) := (OTHERS => '0');
	SIGNAL incg, eincg : SIGNED(24 DOWNTO 0) := (OTHERS => '0');

	-- step number and the grid part of one window line; the 18 device words and two phases are skipped
	PROCEDURE row (l : INOUT LINE; k : OUT INTEGER; vx, vpm, vsh : OUT SIGNED; vps : OUT SIGNED;
		vtk : OUT counts; var : OUT STD_LOGIC_VECTOR) IS
		VARIABLE w40 : STD_LOGIC_VECTOR(39 DOWNTO 0);
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w28 : STD_LOGIC_VECTOR(27 DOWNTO 0);
		VARIABLE w16 : STD_LOGIC_VECTOR(15 DOWNTO 0);
		VARIABLE w4  : STD_LOGIC_VECTOR(3 DOWNTO 0);
	BEGIN
		read(l, k);
		FOR i IN 1 TO 18 LOOP
			hrd(l, w32);
		END LOOP;
		hrd(l, w40);
		hrd(l, w40);
		hrd(l, w32);
		vx := SIGNED(w32);
		hrd(l, w32);
		vpm := SIGNED(w32);
		hrd(l, w28);
		vps := SIGNED(w28);
		hrd(l, w32);
		vsh := SIGNED(w32);
		FOR j IN 0 TO 6 LOOP
			hrd(l, w16);
			vtk(j) := TO_INTEGER(UNSIGNED(w16));
		END LOOP;
		FOR j IN 0 TO 6 LOOP
			hrd(l, w4);
			var(j) := w4(0);
		END LOOP;
	END row;
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow);
	dut : ENTITY work.plant_slow PORT MAP (clk, load, step, slow, c, pg, pg0, dp, cap, x0, pm0, sh0, ps0, tk0, ar0,
		x, pm, shed, psum, ticks, armed, incg);

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
		IF run AND (x /= ex OR pm /= epm OR psum /= eps OR (c >= 2 AND incg /= eincg)
			OR (c <= 12 AND (shed /= esh OR ticks /= etk OR armed /= ear))
			OR (c >= 19 AND (shed /= nsh OR ticks /= ntk OR armed /= nar))) THEN
			cerr <= cerr + 1;
			REPORT "grid state or incg wrong at c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
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
		VARIABLE vx, vpm, vsh : SIGNED(31 DOWNTO 0);
		VARIABLE vps : SIGNED(27 DOWNTO 0);
		VARIABLE vtk : counts;
		VARIABLE var : STD_LOGIC_VECTOR(0 TO 6);
		VARIABLE vpg : SIGNED(17 DOWNTO 0);
		VARIABLE w48 : STD_LOGIC_VECTOR(47 DOWNTO 0);
		VARIABLE w34 : STD_LOGIC_VECTOR(33 DOWNTO 0);
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w26 : STD_LOGIC_VECTOR(25 DOWNTO 0);
		VARIABLE w25 : STD_LOGIC_VECTOR(24 DOWNTO 0);
		VARIABLE w18 : STD_LOGIC_VECTOR(17 DOWNTO 0);
		VARIABLE w2  : STD_LOGIC_VECTOR(1 DOWNTO 0);
	BEGIN
		-- config lines: 23 constants, their 23 F, PH, KPH, KPF, MARGIN, method, limit flag,
		-- p0, trip, cap, imax0, imax_cont, k_trip, k_short, pg0, then x, ticks, shed of each UFLS stage
		FOR i IN cf'RANGE LOOP
			readline(fc, l);
			hrd(l, w48);
			cf(i) := SIGNED(w48);
		END LOOP;
		IF cf(18) /= GH OR cf(19) /= GT OR cf(20) /= KR OR cf(21) /= DD OR cf(22) /= RR OR cf(47) /= KPH
			OR cf(41) /= FGH OR cf(42) /= FGT OR cf(43) /= FKR OR cf(44) /= FDD OR cf(45) /= FRR OR cf(48) /= FKP THEN
			errs := errs + 1;
			REPORT "grid gains differ from the config file" SEVERITY ERROR;
		END IF;
		FOR j IN 0 TO 6 LOOP
			IF cf(60 + 3 * j) /= THR(j) OR cf(61 + 3 * j) /= LIM(j) OR cf(62 + 3 * j) /= AMT(j) THEN
				errs := errs + 1;
				REPORT "UFLS stage " & INTEGER'IMAGE(j) & " differs from the config file" SEVERITY ERROR;
			END IF;
		END LOOP;
		cap <= RESIZE(cf(54), 32);
		pg0 <= RESIZE(cf(59), 18);

		readline(fv, l);
		row(l, k, vx, vpm, vsh, vps, vtk, var);
		k0 <= k MOD 1024;
		x0 <= vx;
		pm0 <= vpm;
		sh0 <= vsh;
		ps0 <= vps;
		tk0 <= vtk;
		ar0 <= var;
		ex <= vx;
		epm <= vpm;
		esh <= vsh;
		eps <= vps;
		etk <= vtk;
		ear <= var;
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		run <= TRUE;
		WHILE NOT endfile(fv) LOOP
			-- _sig line k: v1 x2, limited current x2, lim, exc, dm, inc, incg, pg, sin and cos x4
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
			eincg <= SIGNED(w25);
			hrd(l, w18);
			vpg := SIGNED(w18);
			IF k >= cf(57) THEN
				dp <= RESIZE(cf(53), 32);
			ELSE
				dp <= (OTHERS => '0');
			END IF;
			readline(fv, l);
			row(l, kn, vx, vpm, vsh, vps, vtk, var);
			nsh <= vsh;
			ntk <= vtk;
			nar <= var;
			pg <= NOT vpg;
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 6 FOR 51 * 20 ns;
			pg <= vpg;
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 51 * 20 ns;
			IF step /= '1' THEN
				REPORT "timeout: no step pulse within 51 clocks" SEVERITY FAILURE;
			END IF;
			ex <= vx;
			epm <= vpm;
			eps <= vps;
			esh <= vsh;
			etk <= vtk;
			ear <= var;
			IF kn /= k + 1 THEN
				errs := errs + 1;
				REPORT "step " & INTEGER'IMAGE(k) & ": step number wrong" SEVERITY ERROR;
			END IF;
			k := kn;
			steps := steps + 1;
		END LOOP;
		run <= FALSE;
		WAIT FOR 1 ns;
		IF x /= ex OR pm /= epm OR psum /= eps OR shed /= esh OR ticks /= etk OR armed /= ear THEN
			errs := errs + 1;
			REPORT "last grid state wrong" SEVERITY ERROR;
		END IF;
		errs := errs + cerr;
		ASSERT steps = nsteps AND errs = 0
			REPORT fname & ": FAIL, " & INTEGER'IMAGE(steps) & " steps, " & INTEGER'IMAGE(errs) & " errors"
			SEVERITY FAILURE;
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps, grid state and incg match";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
