LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Checks scen with short times (trip after kt = 4 steps, 0.01 s = 3 steps, limit change after 2 units).
--   the scenario constants in gfm_pkg equal the config files (trip B and trip A), and kt, nc, nw defaults
--   give k_trip and k_short
--   power-up (three clocks, until the switch flip-flops hold values) and KEY0 load the core and read
--   SW0..6 (SW5 vdc, SW6 model as well); after release the settings stay, whatever SW does
--   automatic trip: tr after exactly kt steps, KEY1 ignored; manual: tr at the first step edge after a
--   KEY1 press, never between step edges; dp follows tr and is the trip A or trip B size
--   a switch change on the clock KEY0 is released is not read (two flip-flops, like KEY0)
--   KEY1 boundary: for each of the 5 phases of a press against the step, tr comes at the first step edge
--   at or after the clock the press is detected (detection on the step clock itself included)
--   limit modes: Imax, t2, en and sh for 1.2 pu, 1.2 then 1.0 pu after nw * nc steps from the trip, no
--   limit; mode 11 keeps the core in reset until a reset with a valid mode
--   t counts 0.01 s from the trip and stops at 10000; xmin is the lowest x from the trip on; seen takes
--   lim only at step edges and holds it
ENTITY scen_tb IS
	GENERIC (cname : STRING := "vectors/spec_fb_config.txt"; aname : STRING := "vectors/speca_fb_config.txt");
END scen_tb;

ARCHITECTURE a OF scen_tb IS
	CONSTANT kt : INTEGER := 4;
	CONSTANT nc : INTEGER := 3;
	CONSTANT nw : INTEGER := 2;
	SIGNAL clk, step, lim, load, en, page, pg, fb, ta, au, err, tr, sh, seen, blink, vs, md : STD_LOGIC := '0';
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL key : STD_LOGIC_VECTOR(1 DOWNTO 0) := "11";
	SIGNAL sw : STD_LOGIC_VECTOR(6 DOWNTO 0) := "0000000";
	SIGNAL x, xmin, dp, cap, p0, imx : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL pg0, ks : SIGNED(17 DOWNTO 0);
	SIGNAL t2 : SIGNED(37 DOWNTO 0);
	SIGNAL lm : INTEGER RANGE 0 TO 3;
	SIGNAL t : INTEGER RANGE 0 TO 10000;
	SIGNAL n : INTEGER := 0;
BEGIN
	dut : ENTITY work.scen GENERIC MAP (kt, nc, nw) PORT MAP (clk, step, lim, key, sw, page, x, load, dp, cap, p0, imx,
		pg0, ks, t2, en, lm, pg, fb, ta, au, err, tr, sh, seen, blink, xmin, t, vs, md);

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

	-- a step pulse every fifth clock while the core runs, like tick (c = 0..4 here)
	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			n <= (n + 1) MOD 5;
			IF load = '1' THEN
				n <= 0;
			END IF;
		END IF;
	END PROCESS;
	step <= '1' WHEN n = 4 AND load = '0' ELSE '0';

	PROCESS
		FILE fc : TEXT OPEN READ_MODE IS cname;
		FILE fa : TEXT OPEN READ_MODE IS aname;
		VARIABLE cf, ca : cfgs;
		VARIABLE errs : INTEGER := 0;
		VARIABLE hit : BOOLEAN;
		VARIABLE was : STD_LOGIC;

		PROCEDURE check (ok : BOOLEAN; s : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT s SEVERITY ERROR;
			END IF;
		END check;

		PROCEDURE edges (k : INTEGER) IS             -- wait for k step edges, then for the outputs to settle
		BEGIN
			FOR i IN 1 TO k LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1';
			END LOOP;
			WAIT FOR 1 ns;
		END edges;

		PROCEDURE reset (s : STD_LOGIC_VECTOR) IS        -- SW4..0, or SW6..0
		BEGIN
			sw <= STD_LOGIC_VECTOR(RESIZE(UNSIGNED(s), 7));
			key(0) <= '0';
			FOR i IN 1 TO 6 LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
			WAIT FOR 1 ns;
			check(load = '1', "load not held while KEY0 is down");
			key(0) <= '1';
			FOR i IN 1 TO 3 LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
			sw <= NOT STD_LOGIC_VECTOR(RESIZE(UNSIGNED(s), 7));   -- must not change the settings any more
			WAIT FOR 1 ns;
		END reset;

		FUNCTION th2 (m : SIGNED) RETURN SIGNED IS
			VARIABLE v : SIGNED(31 DOWNTO 0) := RESIZE(m, 32) - SHIFT_RIGHT(RESIZE(m, 32), 11);
		BEGIN
			RETURN RESIZE(SHIFT_RIGHT(v * v, 28), 38);
		END th2;

		PROCEDURE limit (m : SIGNED; e, h : STD_LOGIC; s : STRING) IS
		BEGIN
			check(imx = RESIZE(m, 32) AND t2 = th2(m) AND en = e AND sh = h, "Imax, t2, en or sh wrong: " & s);
		END limit;
	BEGIN
		-- config: ks 17, p0 52, trip 53, cap 54, imax0 55, imax_cont 56, k_trip 57, k_short 58, pg0 59
		cfgread(fc, cf);
		cfgread(fa, ca);
		check(SDA = ca(53) AND ca(17) = cf(17) AND ca(52) = cf(52) AND ca(54) = cf(54) AND ca(57) = cf(57)
			AND ca(58) = cf(58) AND ca(59) = cf(59), "trip A size differs, or trip A changes more than the size");
		check(SKS = cf(17) AND SP0 = cf(52) AND SDP = cf(53) AND SCP = cf(54) AND SI0 = cf(55) AND SI1 = cf(56)
			AND SPG = cf(59), "scenario constants differ from the config file");
		check(SKT = cf(57) AND SNC * SNW = cf(58) - cf(57), "trip or limit change time differs from the config");

		-- power-up: load for the first three clocks only, settings from SW = 00000
		FOR i IN 1 TO 2 LOOP
			WAIT FOR 1 ns;
			check(load = '1', "no load in the first clocks");
			WAIT UNTIL clk = '1' AND clk'EVENT;
		END LOOP;
		WAIT UNTIL clk = '1' AND clk'EVENT;
		WAIT FOR 1 ns;
		check(load = '0' AND fb = '0' AND lm = 0 AND ta = '0' AND au = '0' AND err = '0', "power-up settings wrong");
		check(p0 = cf(52) AND cap = cf(54) AND pg0 = cf(59) AND ks = 0 AND dp = 0, "constant inputs wrong");
		limit(cf(55), '1', '0', "1.2 pu");

		-- automatic trip, fb, 1.2 then 1.0 pu; KEY1 must do nothing
		reset("10011");
		check(fb = '1' AND lm = 1 AND ta = '0' AND au = '1' AND ks = cf(17), "settings not kept after reset");
		key(1) <= '0';
		x <= TO_SIGNED(-100, 32);
		edges(kt - 1);
		check(tr = '0' AND dp = 0, "automatic trip too early, or KEY1 not ignored");
		key(1) <= '1';
		edges(1);
		check(tr = '1' AND dp = cf(53), "no automatic trip after kt steps");
		FOR j IN 1 TO nw * nc LOOP                   -- post-trip steps
			x <= TO_SIGNED(-100 - 10 * ((j * 7) MOD 5), 32);
			IF j = 3 THEN
				lim <= '1';
			END IF;
			WAIT UNTIL clk = '1' AND clk'EVENT;
			lim <= '0';
			check(seen = '0', "seen took lim between step edges");
			edges(1);
			check(t = j / nc, "timer wrong");
			IF j < nw * nc THEN
				limit(cf(55), '1', '0', "before the change");
			ELSE
				limit(cf(56), '1', '1', "after the change");
			END IF;
		END LOOP;
		check(xmin = -140, "xmin is not the lowest x after the trip");
		lim <= '1';
		edges(1);
		lim <= '0';
		edges(2);
		check(seen = '1', "seen not set or not held");

		-- manual trip A, sat, no limit
		reset("01100");
		check(fb = '0' AND lm = 2 AND ta = '1' AND au = '0' AND ks = 0,
			"settings for manual, trip A, sat, no limit wrong");
		limit(TO_SIGNED(2 ** 28, 32), '0', '0', "no limit");
		edges(kt + 3);
		check(tr = '0', "trip without KEY1");
		WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1';
		key(1) <= '0';
		FOR i IN 1 TO 3 LOOP
			WAIT UNTIL clk = '1' AND clk'EVENT;
		END LOOP;
		WAIT FOR 1 ns;
		check(tr = '0', "trip before the step edge");
		edges(1);
		check(tr = '1' AND dp = ca(53), "no trip A at the step edge after KEY1");
		key(1) <= '1';
		edges(10000 * nc - 1);
		check(t = 9999, "timer wrong just before 100 s");
		edges(1 + 3 * nc);
		check(t = 10000 AND tr = '1', "timer does not stop at 10000 or trip lost");
		limit(TO_SIGNED(2 ** 28, 32), '0', '0', "no limit after 10000 units");

		-- reserved mode: the core stays in reset until a valid reset
		reset("00110");
		FOR i IN 1 TO 20 LOOP
			WAIT UNTIL clk = '1' AND clk'EVENT;
		END LOOP;
		WAIT FOR 1 ns;
		check(err = '1' AND load = '1' AND tr = '0', "mode 11 does not hold the core in reset");
		reset("00000");
		check(err = '0' AND load = '0' AND lm = 0, "valid reset does not clear mode 11");

		-- switches pass two flip-flops: a change at the clock KEY0 is released comes too late to be read
		sw <= "0000000";
		key(0) <= '0';
		FOR i IN 1 TO 6 LOOP
			WAIT UNTIL clk = '1' AND clk'EVENT;
		END LOOP;
		key(0) <= '1';
		sw <= "1111011";
		FOR i IN 1 TO 6 LOOP
			WAIT UNTIL clk = '1' AND clk'EVENT;
		END LOOP;
		WAIT FOR 1 ns;
		check(fb = '0' AND lm = 0 AND ta = '0' AND au = '0' AND vs = '0' AND md = '0',
			"switches read without their two flip-flops");
		reset("1100000");                            -- SW5 vdc 4.0 pu, SW6 PWM, held after release
		check(vs = '1' AND md = '1' AND fb = '0', "SW5 or SW6 not read at reset");
		reset("0100000");
		check(vs = '1' AND md = '0', "SW6 not read at reset");

		-- KEY1 pressed in each phase of the step
		FOR ph IN 0 TO 4 LOOP
			reset("00000");
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1';
			FOR i IN 1 TO ph LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
			key(1) <= '0';
			hit := FALSE;
			FOR i IN 1 TO 12 LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
				was := step;                         -- step during the clock this edge ends
				WAIT FOR 1 ns;
				IF NOT hit AND i >= 3 AND was = '1' THEN
					check(tr = '1', "KEY1 in phase " & INTEGER'IMAGE(ph) & ": no trip at the first step edge");
					hit := TRUE;
				ELSIF NOT hit THEN
					check(tr = '0', "KEY1 in phase " & INTEGER'IMAGE(ph) & ": trip too early");
				END IF;
			END LOOP;
			key(1) <= '1';
		END LOOP;

		ASSERT errs = 0 REPORT "scen: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "scen: PASS, settings, trip, limit modes, timer and records";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
