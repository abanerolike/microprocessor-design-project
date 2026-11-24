LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Closed-loop check of the whole emulator against one vector window and its config file.
--   only the first line is loaded (all states and the step position); after that the loop runs on its
--   own. From outside come the scenario inputs of step k only: the lost generation from k_trip on, Imax
--   of step k (imax0 before k_short, imax_cont after; 2 pu or more means no limit) with t2 and en from
--   the same value, and the fixed p0, cap, pg0, ks
--   every clock of step k: the 18 device and controller words, both phases, x, pm and psum equal line k;
--   shed, ticks and armed equal line k up to c = 12 and line k+1 from c = 19
--   and the node values equal the _sig line k: sn, sg, incg from c = 2, cs, cg from 3, pg from 6,
--   lim from 14, exc from 23, il re from 26 and im from 27, dm from 28, inc from 30, v1 from 33
--   the run ends with every line read, exactly nsteps steps, the last state right, and no errors
-- pwm = TRUE: a window of vectors/pwm with the PWM model (md = 1, vdc by vdc40). The PWM starts from the
--   line's PWM words (a window at step 0 from the board's start values); the _sig line has v1 only of the
--   nodes above, so the check is every state word at every clock and v1 from c = 33
-- hold: go drops at random clocks (pause, slow motion): the core must hold at c = 45 and then go on
--   exactly as without the holds, so every check above stays as it is
-- pre > 0: before the window the loop first runs pre steps with the PWM at the other vdc from the board
--   start, so a reset must leave nothing of that run behind
ENTITY core_tb IS
	GENERIC (fname : STRING := "vectors/held_sat_ufls"; cname : STRING := "vectors/held_sat_config.txt";
		nsteps : INTEGER := 2048; pwm, vdc40, hold : BOOLEAN := FALSE; pre : INTEGER := 0);
END core_tb;

ARCHITECTURE a OF core_tb IS
	CONSTANT ONE : SIGNED(31 DOWNTO 0) := SHIFT_LEFT(TO_SIGNED(1, 32), 28);
	SIGNAL clk, load, step, en, lim : STD_LOGIC := '0';
	SIGNAL k0 : INTEGER RANGE 0 TO 1023 := 0;
	SIGNAL c  : INTEGER RANGE 0 TO 49;
	SIGNAL done, run : BOOLEAN := FALSE;
	SIGNAL cerr : INTEGER := 0;
	SIGNAL dp, cap, p0, imx, x0, pm0, sh0, x, pm, shed, ex, epm, esh, nsh : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL pg0, ks, cs, sn, cg, sg, pg, dm : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL t2 : SIGNED(37 DOWNTO 0) := (OTHERS => '0');
	SIGNAL d0, d, ed : words(0 TO 17) := (OTHERS => (OTHERS => '0'));
	SIGNAL th0, thg0, th, thg, eth, ethg : UNSIGNED(39 DOWNTO 0) := (OTHERS => '0');
	SIGNAL ps0, psum, eps : SIGNED(27 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tk0, ticks, etk, ntk : counts := (OTHERS => 0);
	SIGNAL ar0, armed, ear, nar : STD_LOGIC_VECTOR(0 TO 6) := (OTHERS => '0');
	SIGNAL il : words(0 TO 1);
	SIGNAL exc : SIGNED(32 DOWNTO 0);
	SIGNAL v1r, v1i : SIGNED(33 DOWNTO 0);
	SIGNAL inc : SIGNED(25 DOWNTO 0);
	SIGNAL incg : SIGNED(24 DOWNTO 0);
	SIGNAL e : sigs := (OTHERS => (OTHERS => '0'));
	SIGNAL md, vs, hl : STD_LOGIC := '0';
	SIGNAL go : STD_LOGIC := '1';
	SIGNAL wq0 : INTEGER RANGE 0 TO 249 := 0;
	SIGNAL wth0 : UNSIGNED(39 DOWNTO 0) := ST_KN;            -- the board start, so the PWM never sees 'U'
	SIGNAL wc0 : SIGNED(17 DOWNTO 0) := TO_SIGNED(65536, 18);
	SIGNAL ws0 : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL wda0, wdp0 : duties := ST_DU('0');
	SIGNAL wdc0 : deads := (100, 100, 100);
	SIGNAL wcm0 : STD_LOGIC_VECTOR(0 TO 2) := "111";
	SIGNAL wng0 : STD_LOGIC_VECTOR(0 TO 2) := ST_NG;
	SIGNAL wur0 : SIGNED(33 DOWNTO 0) := TO_SIGNED(ST_V1R, 34);
	SIGNAL wui0 : SIGNED(33 DOWNTO 0) := TO_SIGNED(ST_V1I, 34);

	-- one whole window line: step number, the 18 words, both phases, then the grid part
	PROCEDURE whole (l : INOUT LINE; k : OUT INTEGER; vd : OUT words; vth, vthg : OUT UNSIGNED;
		vx, vpm, vsh : OUT SIGNED; vps : OUT SIGNED; vtk : OUT counts; var : OUT STD_LOGIC_VECTOR) IS
		VARIABLE r : row18;
		VARIABLE w40 : STD_LOGIC_VECTOR(39 DOWNTO 0);
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w28 : STD_LOGIC_VECTOR(27 DOWNTO 0);
		VARIABLE w16 : STD_LOGIC_VECTOR(15 DOWNTO 0);
		VARIABLE w4  : STD_LOGIC_VECTOR(3 DOWNTO 0);
	BEGIN
		rowread(l, k, r);
		FOR i IN 0 TO 17 LOOP
			vd(i) := r(i);
		END LOOP;
		hrd(l, w40);
		vth := UNSIGNED(w40);
		hrd(l, w40);
		vthg := UNSIGNED(w40);
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
	END whole;
BEGIN
	dut : ENTITY work.core PORT MAP (clk, load, k0, dp, cap, pg0, ks, p0, imx, t2, en, d0, th0, thg0, x0, pm0, sh0,
		ps0, tk0, ar0, c, step, d, th, thg, x, pm, shed, psum, ticks, armed, cs, sn, cg, sg, pg, dm, il, lim, exc,
		v1r, v1i, inc, incg, md, vs, wq0, wth0, wc0, ws0, wda0, wdp0, wdc0, wcm0, wng0, wur0, wui0, go, hl);

	PROCESS                                          -- random holds: go low for 1..16 clocks, now and then
		VARIABLE lf : UNSIGNED(15 DOWNTO 0) := X"BEEF";
	BEGIN
		WAIT UNTIL clk = '1' AND clk'EVENT;
		lf := lf(14 DOWNTO 0) & (lf(15) XOR lf(13) XOR lf(12) XOR lf(10));
		IF hold AND lf(3 DOWNTO 0) = "0000" THEN
			go <= '0';
			FOR i IN 0 TO TO_INTEGER(lf(7 DOWNTO 4)) LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
			go <= '1';
		END IF;
	END PROCESS;

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
		IF run AND (d /= ed OR th /= eth OR thg /= ethg OR x /= ex OR pm /= epm OR psum /= eps
			OR (c <= 12 AND (shed /= esh OR ticks /= etk OR armed /= ear))
			OR (c >= 19 AND (shed /= nsh OR ticks /= ntk OR armed /= nar))
			OR (NOT pwm AND ((c >= 2 AND (sn /= e(11) OR sg /= e(13) OR incg /= e(8)))
			OR (c >= 3 AND (cs /= e(10) OR cg /= e(12))) OR (c >= 6 AND pg /= e(9))
			OR (c >= 14 AND (lim = '1') /= (e(4) = 1)) OR (c >= 23 AND exc /= e(5))
			OR (c >= 26 AND il(0) /= e(2)) OR (c >= 27 AND il(1) /= e(3)) OR (c >= 28 AND dm /= e(6))
			OR (c >= 30 AND inc /= e(7))))
			OR (c >= 33 AND (v1r /= e(0) OR v1i /= e(1)))) THEN
			cerr <= cerr + 1;
			REPORT "state or node wrong at c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
		END IF;
	END PROCESS;

	PROCESS
		FILE fc : TEXT OPEN READ_MODE IS cname;
		FILE fv : TEXT OPEN READ_MODE IS fname & ".txt";
		FILE fs : TEXT OPEN READ_MODE IS fname & "_sig.txt";
		VARIABLE l : LINE;
		VARIABLE cf : cfgs;
		VARIABLE v : sigs;
		VARIABLE k, kn, steps, errs : INTEGER := 0;
		VARIABLE vd : words(0 TO 17);
		VARIABLE vth, vthg : UNSIGNED(39 DOWNTO 0);
		VARIABLE vx, vpm, vsh, m, thr : SIGNED(31 DOWNTO 0);
		VARIABLE vps : SIGNED(27 DOWNTO 0);
		VARIABLE vtk : counts;
		VARIABLE var : STD_LOGIC_VECTOR(0 TO 6);
		VARIABLE mm : SIGNED(47 DOWNTO 0);
		VARIABLE l2 : LINE;
		VARIABLE pr : pwords;
		VARIABLE ps : swords;

		PROCEDURE nodes IS                           -- the _sig line of this step
		BEGIN
			readline(fs, l);
			IF pwm THEN
				psig(l, ps);
				v := (OTHERS => (OTHERS => '0'));
				v(0) := RESIZE(ps.v1r, 36);
				v(1) := RESIZE(ps.v1i, 36);
			ELSE
				sigread(l, v);
			END IF;
		END nodes;
	BEGIN
		-- config: ks 17 (F 40), method_fb 50, p0 52, trip 53, cap 54, imax0 55, imax_cont 56, k_trip 57,
		-- k_short 58, pg0 59
		cfgread(fc, cf);
		IF (cf(17) /= 0 AND cf(40) /= FKS) OR (cf(50) = 0 AND cf(17) /= 0) THEN
			errs := errs + 1;
			REPORT "ks is not at F 19, or fb is off and ks is not 0" SEVERITY ERROR;
		END IF;
		ks <= RESIZE(cf(17), 18);
		p0 <= RESIZE(cf(52), 32);
		cap <= RESIZE(cf(54), 32);
		pg0 <= RESIZE(cf(59), 18);

		IF pre > 0 THEN                              -- an earlier run with the other vdc
			md <= '1';
			vs <= '1';
			wda0 <= ST_DU('1');
			wdp0 <= ST_DU('1');
			IF vdc40 THEN
				vs <= '0';
				wda0 <= ST_DU('0');
				wdp0 <= ST_DU('0');
			END IF;
			wq0 <= 0;
			wth0 <= ST_KN;
			wdc0 <= (100, 100, 100);
			wcm0 <= "111";
			wng0 <= ST_NG;
			wur0 <= TO_SIGNED(ST_V1R, 34);
			wui0 <= TO_SIGNED(ST_V1I, 34);
			wc0 <= TO_SIGNED(65536, 18);
			ws0 <= (OTHERS => '0');
			d0 <= ST_D;
			th0 <= ST_TH;
			ar0 <= "1111111";
			p0 <= RESIZE(cf(52), 32);
			imx <= RESIZE(cf(55), 32);
			en <= '1';
			load <= '1';
			WAIT UNTIL clk = '1' AND clk'EVENT;
			load <= '0';
			FOR i IN 1 TO pre * 50 LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
		END IF;
		readline(fv, l);
		l2 := NEW STRING'(l.ALL);
		whole(l, k, vd, vth, vthg, vx, vpm, vsh, vps, vtk, var);
		k0 <= k MOD 1024;
		md <= '0';
		vs <= '0';
		IF pwm THEN                                  -- PWM start: as in pwm_tb
			md <= '1';
			IF vdc40 THEN
				vs <= '1';
			END IF;
			prow(l2, pr);
			nodes;
			wq0 <= k MOD 250;
			wth0 <= ps.ph + ST_KN;
			IF pr.flag = 1 THEN
				wda0 <= ST_DU('0');
				wdp0 <= ST_DU('0');
				IF vdc40 THEN
					wda0 <= ST_DU('1');
					wdp0 <= ST_DU('1');
				END IF;
				wdc0 <= (100, 100, 100);
				wcm0 <= "111";
				wng0 <= ST_NG;
				wur0 <= TO_SIGNED(ST_V1R, 34);
				wui0 <= TO_SIGNED(ST_V1I, 34);
				wc0 <= TO_SIGNED(65536, 18);
				ws0 <= (OTHERS => '0');
			ELSE
				wda0 <= pr.da;
				IF k MOD 125 = 0 THEN
					wda0 <= pr.dp;
				END IF;
				wdp0 <= pr.dp;
				wdc0 <= pr.dc;
				wcm0 <= pr.cm;
				wng0 <= ps.ng;
				wur0 <= pr.ur;
				wui0 <= pr.ui;
				wc0 <= ps.ck;
				ws0 <= ps.sk;
			END IF;
		END IF;
		d0 <= vd;
		th0 <= vth;
		thg0 <= vthg;
		x0 <= vx;
		pm0 <= vpm;
		sh0 <= vsh;
		ps0 <= vps;
		tk0 <= vtk;
		ar0 <= var;
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		run <= TRUE;
		WHILE NOT endfile(fv) LOOP
			ed <= vd;
			eth <= vth;
			ethg <= vthg;
			ex <= vx;
			epm <= vpm;
			eps <= vps;
			esh <= vsh;
			etk <= vtk;
			ear <= var;
			dp <= (OTHERS => '0');
			IF k >= cf(57) THEN
				dp <= RESIZE(cf(53), 32);
			END IF;
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
			IF NOT pwm OR steps > 0 THEN              -- the PWM start has read the first _sig line
				nodes;
			END IF;
			e <= v;
			readline(fv, l);
			whole(l, kn, vd, vth, vthg, vx, vpm, vsh, vps, vtk, var);
			nsh <= vsh;
			ntk <= vtk;
			nar <= var;
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 2000 * 20 ns;
			IF step /= '1' THEN
				REPORT "timeout: no step pulse" SEVERITY FAILURE;
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
		IF d /= vd OR th /= vth OR thg /= vthg OR x /= vx OR pm /= vpm OR psum /= vps OR shed /= vsh
			OR ticks /= vtk OR armed /= var THEN
			errs := errs + 1;
			REPORT "last state wrong" SEVERITY ERROR;
		END IF;
		errs := errs + cerr;
		ASSERT steps = nsteps AND errs = 0
			REPORT fname & ": FAIL, " & INTEGER'IMAGE(steps) & " steps, " & INTEGER'IMAGE(errs) & " errors"
			SEVERITY FAILURE;
		REPORT fname & ": PASS, " & INTEGER'IMAGE(steps) & " steps, closed loop matches";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
