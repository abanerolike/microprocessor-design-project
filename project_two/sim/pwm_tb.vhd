LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- PWM block alone against one window of vectors/pwm, tick by tick.
--   load comes with en = 0 (load wins): the start values of the window (a window at step 0 takes the
--   start of pwm_config.txt, as the board will); then c runs 0..49 per step
--   inputs: v1 of step k from c = 33, the plant's new i1 (line k+1) re from c = 36 and im from c = 37,
--   inverted before that, so an early read shows
--   every tick is checked against a reference written here from the same rules: the active duty, and
--   after the edge the leg, gate command and dead-time count of each leg. The reference takes the duty
--   at each carrier end from the _sig line (the pending duty made in the step before)
--   each step: the current signs equal the _sig line, the nominal phase (c <= 24) equals phi(k + 1),
--   u from c = 7 equals line k, the pending duty from c = 44 equals the _sig line, and at the end the
--   counts equal the _sig line and the gate commands and counters equal line k+1
--   pause: en drops at random clocks (c and the inputs hold too); nothing in the block may change then
--   force: the window starts from duties 6250, 0, 3125 (the vectors never reach 6250); the checks that
--   follow from line k+1 and the counts are off, the tick reference and the pending duty stay on
ENTITY pwm_tb IS
	GENERIC (fname : STRING := "vectors/pwm/held_sat_24_clip"; vdc40, pause, force : BOOLEAN := FALSE;
		nsteps : INTEGER := 2048);
END pwm_tb;

ARCHITECTURE a OF pwm_tb IS
	CONSTANT KN : UNSIGNED(39 DOWNTO 0) := TO_UNSIGNED(65970688, 40);
	SIGNAL clk, load, en, vsel : STD_LOGIC := '0';
	SIGNAL c : INTEGER RANGE 0 TO 49 := 0;
	SIGNAL q0 : INTEGER RANGE 0 TO 249 := 0;
	SIGNAL v1r, v1i, ur0, ui0, ur, ui : SIGNED(33 DOWNTO 0) := (OTHERS => '0');
	SIGNAL n1r, n1i : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL th0, th : UNSIGNED(39 DOWNTO 0) := (OTHERS => '0');
	SIGNAL c0, s0 : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL da0, dp0, dact, dpen : duties := (OTHERS => 0);
	SIGNAL dc0, dct : deads := (OTHERS => 0);
	SIGNAL cm0, ng0, leg, cmd, ng : STD_LOGIC_VECTOR(0 TO 2) := (OTHERS => '0');
	SIGNAL done : BOOLEAN := FALSE;

BEGIN
	clk <= NOT clk AFTER 10 ns WHEN NOT done;

	dut : ENTITY work.pwm PORT MAP (clk, load, en, vsel, c, v1r, v1i, n1r, n1i, q0, th0, c0, s0, da0, dp0, dc0,
		cm0, ng0, ur0, ui0, ur, ui, leg, cmd, ng, dact, dpen, dct, th);

	PROCESS
		FILE fv : TEXT OPEN READ_MODE IS fname & ".txt";
		FILE fs : TEXT OPEN READ_MODE IS fname & "_sig.txt";
		FILE fc : TEXT OPEN READ_MODE IS "vectors/pwm/pwm_config.txt";
		TYPE cfg IS ARRAY (0 TO 25) OF SIGNED(47 DOWNTO 0);
		VARIABLE l : LINE;
		VARIABLE w : STD_LOGIC_VECTOR(47 DOWNTO 0);
		VARIABLE cf : cfg;
		VARIABLE cur, nxt : pwords;
		VARIABLE sg : swords;
		VARIABLE rd : duties;                           -- reference: active duty, command, counter, counts
		VARIABLE rc : STD_LOGIC_VECTOR(0 TO 2);
		VARIABLE rt : deads;
		VARIABLE rn : duties;
		VARIABLE cm, hi : STD_LOGIC;
		VARIABLE tq, cr, j, errs, nst, b : INTEGER := 0;
		VARIABLE lf : UNSIGNED(15 DOWNTO 0) := X"ACE1";
		VARIABLE snap : STD_LOGIC_VECTOR(0 TO 8);

		PROCEDURE check (ok : BOOLEAN; m : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				IF errs <= 10 THEN
					REPORT m & " at step " & INTEGER'IMAGE(cur.k) & ", c = " & INTEGER'IMAGE(c) SEVERITY ERROR;
				END IF;
			END IF;
		END check;
	BEGIN
		FOR i IN cf'RANGE LOOP
			readline(fc, l);
			hrd(l, w);
			cf(i) := SIGNED(w);
		END LOOP;
		readline(fv, l);
		prow(l, cur);
		readline(fs, l);
		psig(l, sg);
		b := 0;
		IF vdc40 THEN
			b := 9;
			vsel <= '1';
		END IF;
		IF cur.flag = 1 THEN                            -- step 0: the board's start values
			FOR x IN 0 TO 2 LOOP
				rd(x) := TO_INTEGER(cf(10 + b + x));
				rc(x) := cf(13 + b + x)(0);
				rt(x) := 100;
			END LOOP;
			dp0 <= rd;
			ng0 <= (cf(25)(0), cf(25)(1), cf(25)(2));
			cur.ur := RESIZE(cf(5), 34);                -- u of the first step is the start v1
			cur.ui := RESIZE(cf(6), 34);
			ur0 <= cur.ur;
			ui0 <= cur.ui;
			c0 <= TO_SIGNED(65536, 18);
			s0 <= (OTHERS => '0');
		ELSE
			rd := cur.da;
			IF cur.k MOD 125 = 0 THEN
				rd := cur.dp;
			END IF;
			rc := cur.cm;
			rt := cur.dc;
			dp0 <= cur.dp;
			ng0 <= sg.ng;
			ur0 <= cur.ur;
			ui0 <= cur.ui;
			c0 <= sg.ck;
			s0 <= sg.sk;
		END IF;
		IF force THEN
			rd := (6250, 0, 3125);
		END IF;
		da0 <= rd;
		cm0 <= rc;
		dc0 <= rt;
		q0 <= cur.k MOD 250;
		th0 <= sg.ph + KN;
		load <= '1';                                    -- with en = 0: load must still win
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';

		WHILE NOT endfile(fv) LOOP
			readline(fv, l);
			prow(l, nxt);
			rn := (0, 0, 0);
			FOR cc IN 0 TO 49 LOOP
				c <= cc;
				v1r <= sg.v1r;
				v1i <= sg.v1i;
				IF cc < 33 THEN
					v1r <= NOT sg.v1r;
					v1i <= NOT sg.v1i;
				END IF;
				n1r <= nxt.i1r;
				n1i <= nxt.i1i;
				IF cc < 36 THEN
					n1r <= NOT nxt.i1r;
				END IF;
				IF cc < 37 THEN
					n1i <= NOT nxt.i1i;
				END IF;
				en <= '1';
				LOOP                                    -- random pauses: c and the inputs hold
					lf := lf(14 DOWNTO 0) & (lf(15) XOR lf(13) XOR lf(12) XOR lf(10));
					EXIT WHEN NOT pause OR lf(2 DOWNTO 0) /= "000";
					en <= '0';
					snap := leg & cmd & ng;
					WAIT UNTIL clk = '1' AND clk'EVENT;
					WAIT FOR 1 ns;
					check(leg & cmd & ng = snap AND dact = rd AND dct = rt, "a register changed while en = 0");
					en <= '1';
				END LOOP;
				WAIT FOR 1 ns;
				check(dact = rd, "active duty");
				check(ng = sg.ng, "current signs");
				IF cc <= 24 THEN
					check(th = sg.ph + KN, "nominal phase");
				END IF;
				IF cc >= 7 AND NOT force THEN
					check(ur = cur.ur AND ui = cur.ui, "u");
				END IF;
				IF cc >= 44 THEN
					check(dpen = sg.dp, "pending duty");
				END IF;
				tq := (50 * cur.k + cc) MOD 12500;
				cr := tq;
				IF tq > 6250 THEN
					cr := 12500 - tq;
				END IF;
				FOR x IN 0 TO 2 LOOP                     -- the reference tick
					cm := '0';
					IF rd(x) > cr THEN
						cm := '1';
					END IF;
					IF cm /= rc(x) THEN
						rc(x) := cm;
						rt(x) := 0;
					END IF;
					hi := sg.ng(x);
					IF rt(x) = 100 THEN
						hi := cm;
					END IF;
					IF rt(x) < 100 THEN
						rt(x) := rt(x) + 1;
					END IF;
					IF hi = '1' THEN
						rn(x) := rn(x) + 1;
					END IF;
					snap(x) := hi;
				END LOOP;
				WAIT UNTIL clk = '1' AND clk'EVENT;
				WAIT FOR 1 ns;
				check(leg = snap(0 TO 2) AND cmd = rc AND dct = rt, "tick: leg, gate command or dead-time count");
			END LOOP;
			IF NOT force THEN
				check(rn = sg.n, "counts of the step");
				check(cmd = nxt.cm AND dct = nxt.dc, "gate commands or counters after the step");
			END IF;
			IF (cur.k + 1) MOD 125 = 0 THEN
				rd := sg.dp;
			END IF;
			nst := nst + 1;
			cur := nxt;
			EXIT WHEN endfile(fs);
			readline(fs, l);
			psig(l, sg);
		END LOOP;
		IF nst /= nsteps OR errs /= 0 THEN
			REPORT "pwm: FAIL, " & INTEGER'IMAGE(nst) & " steps, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		END IF;
		REPORT "pwm: PASS, " & INTEGER'IMAGE(nst) & " steps checked tick by tick" SEVERITY NOTE;
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
