LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Text over the graphs, 16 x 16 pixels per character (the 8 x 8 font doubled), 40 columns. Text lines
-- start on any multiple of 8 pixels, so the screen is 60 half rows of 8 pixels; a character fills two.
--   fixed text (labels, axis numbers, legend) is a ROM of 60 x 40 cells built when the design is
--   elaborated: character number, which half, colour
--   half rows 0..1, 4..5 and 6..7 are rebuilt in vertical blank from the settings and the HEX values:
--   settings and state, F and MIN with OK or LOW, SHED and T. The legend's reference digit (59.2 or
--   59.7 Hz) follows the trip type. All inputs are taken in vertical blank, so a frame shows one copy.
--   dd, db, dt, lo come from the HEX display buffer: digits (value v digit i at 16 v + 4 i, values f,
--   lowest f, shed, time, PK), out-of-range flags, the trip flag and the lowest x of the same copy.
--   PK (largest |i1| since the trip, 0.001 pu) goes on the current legend line, half rows 28..29.
--   The model in use goes at the end of the conditions line (half rows 2..3, columns 28..39): AVG (no
--   vdc: the average model has none) or PWM with the vdc read at reset.
--   MIN OK: the lowest x (not the rounded digits) is at or above 59.7 Hz for trip A, 59.2 Hz for trip B
--   (-0.3/60 and -0.8/60 pu in Q31, rounded up). LOW once below.
--   pipeline (one stage per pixel clock, as in scope): 1 ROM address, 2 character and font address,
--   3 font row read: ton and tc are ready for the third stage.
-- cmp = 1, comparison view (its own fixed ROM): the settings line carries the model in its gap; half rows
-- 2..7 become a table: header, NOW (this run, live), PREV (pv: the kept copy of the previous run, taken
-- at the end of its last written column); the time axis is from the reset; T in the table is time since
-- the trip. Half rows 53..56: the previous run's settings, then SAME SETUP, SAME SETUP EXCEPT SAT VS FB
-- (only fb differs), MANUAL TIMING (a run without the automatic trip: trip times may differ) or DIFF SETUP.
-- The state field shows STEP or PAUSE while the model is held, and the ratio in slow motion.
ENTITY text IS
	PORT (clk, pe, vb, ta, fb, sh, au, tr, dt : IN STD_LOGIC;
		hc  : IN INTEGER RANGE 0 TO 799;
		vc  : IN INTEGER RANGE 0 TO 524;
		lm  : IN INTEGER RANGE 0 TO 3;
		dd  : IN STD_LOGIC_VECTOR(79 DOWNTO 0);
		db  : IN STD_LOGIC_VECTOR(0 TO 4);
		lo  : IN SIGNED(31 DOWNTO 0);
		ton : OUT STD_LOGIC;
		tc  : OUT STD_LOGIC_VECTOR(29 DOWNTO 0);
		md, vs : IN STD_LOGIC := '0';                  -- PWM model, vdc 4.0 pu
		cmp, ps, bz : IN STD_LOGIC := '0';             -- comparison view, paused, step run going
		sl  : IN INTEGER RANGE 0 TO 3 := 0;            -- slow motion 1:1, 1:4, 1:10, 1:100
		pv  : IN shown := NONE);
END text;

ARCHITECTURE a OF text IS
	CONSTANT CHARS : STRING := " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ.:()-=%zpus";
	TYPE codes IS ARRAY (NATURAL RANGE <>) OF INTEGER RANGE 0 TO 63;
	TYPE cells IS ARRAY (0 TO 2399) OF INTEGER RANGE 0 TO 1023;          -- code + 64 half + 128 colour
	TYPE rows IS ARRAY (0 TO 383) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
	TYPE colours IS ARRAY (0 TO 7) OF STD_LOGIC_VECTOR(29 DOWNTO 0);
	CONSTANT FONT : rows := (
		x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",   -- ' '
		x"38", x"44", x"4C", x"54", x"64", x"44", x"38", x"00",   -- '0'
		x"10", x"30", x"10", x"10", x"10", x"10", x"38", x"00",   -- '1'
		x"38", x"44", x"04", x"08", x"10", x"20", x"7C", x"00",   -- '2'
		x"7C", x"08", x"10", x"08", x"04", x"44", x"38", x"00",   -- '3'
		x"08", x"18", x"28", x"48", x"7C", x"08", x"08", x"00",   -- '4'
		x"7C", x"40", x"78", x"04", x"04", x"44", x"38", x"00",   -- '5'
		x"18", x"20", x"40", x"78", x"44", x"44", x"38", x"00",   -- '6'
		x"7C", x"04", x"08", x"10", x"20", x"20", x"20", x"00",   -- '7'
		x"38", x"44", x"44", x"38", x"44", x"44", x"38", x"00",   -- '8'
		x"38", x"44", x"44", x"3C", x"04", x"08", x"30", x"00",   -- '9'
		x"38", x"44", x"44", x"7C", x"44", x"44", x"44", x"00",   -- 'A'
		x"78", x"44", x"44", x"78", x"44", x"44", x"78", x"00",   -- 'B'
		x"38", x"44", x"40", x"40", x"40", x"44", x"38", x"00",   -- 'C'
		x"70", x"48", x"44", x"44", x"44", x"48", x"70", x"00",   -- 'D'
		x"7C", x"40", x"40", x"78", x"40", x"40", x"7C", x"00",   -- 'E'
		x"7C", x"40", x"40", x"78", x"40", x"40", x"40", x"00",   -- 'F'
		x"38", x"44", x"40", x"5C", x"44", x"44", x"3C", x"00",   -- 'G'
		x"44", x"44", x"44", x"7C", x"44", x"44", x"44", x"00",   -- 'H'
		x"38", x"10", x"10", x"10", x"10", x"10", x"38", x"00",   -- 'I'
		x"1C", x"08", x"08", x"08", x"08", x"48", x"30", x"00",   -- 'J'
		x"44", x"48", x"50", x"60", x"50", x"48", x"44", x"00",   -- 'K'
		x"40", x"40", x"40", x"40", x"40", x"40", x"7C", x"00",   -- 'L'
		x"44", x"6C", x"54", x"54", x"44", x"44", x"44", x"00",   -- 'M'
		x"44", x"44", x"64", x"54", x"4C", x"44", x"44", x"00",   -- 'N'
		x"38", x"44", x"44", x"44", x"44", x"44", x"38", x"00",   -- 'O'
		x"78", x"44", x"44", x"78", x"40", x"40", x"40", x"00",   -- 'P'
		x"38", x"44", x"44", x"44", x"54", x"48", x"34", x"00",   -- 'Q'
		x"78", x"44", x"44", x"78", x"50", x"48", x"44", x"00",   -- 'R'
		x"3C", x"40", x"40", x"38", x"04", x"04", x"78", x"00",   -- 'S'
		x"7C", x"10", x"10", x"10", x"10", x"10", x"10", x"00",   -- 'T'
		x"44", x"44", x"44", x"44", x"44", x"44", x"38", x"00",   -- 'U'
		x"44", x"44", x"44", x"44", x"44", x"28", x"10", x"00",   -- 'V'
		x"44", x"44", x"44", x"54", x"54", x"54", x"28", x"00",   -- 'W'
		x"44", x"44", x"28", x"10", x"28", x"44", x"44", x"00",   -- 'X'
		x"44", x"44", x"28", x"10", x"10", x"10", x"10", x"00",   -- 'Y'
		x"7C", x"04", x"08", x"10", x"20", x"40", x"7C", x"00",   -- 'Z'
		x"00", x"00", x"00", x"00", x"00", x"30", x"30", x"00",   -- '.'
		x"00", x"30", x"30", x"00", x"30", x"30", x"00", x"00",   -- ':'
		x"08", x"10", x"20", x"20", x"20", x"10", x"08", x"00",   -- '('
		x"20", x"10", x"08", x"08", x"08", x"10", x"20", x"00",   -- ')'
		x"00", x"00", x"00", x"7C", x"00", x"00", x"00", x"00",   -- '-'
		x"00", x"00", x"7C", x"00", x"7C", x"00", x"00", x"00",   -- '='
		x"60", x"64", x"08", x"10", x"20", x"4C", x"0C", x"00",   -- '%'
		x"00", x"00", x"7C", x"08", x"10", x"20", x"7C", x"00",   -- 'z'
		x"00", x"00", x"78", x"44", x"78", x"40", x"40", x"00",   -- 'p'
		x"00", x"00", x"44", x"44", x"44", x"4C", x"34", x"00",   -- 'u'
		x"00", x"00", x"3C", x"40", x"38", x"04", x"78", x"00"   -- 's'
	);

	FUNCTION c (r, g, b : INTEGER) RETURN STD_LOGIC_VECTOR IS
	BEGIN
		RETURN STD_LOGIC_VECTOR(TO_UNSIGNED(r, 10) & TO_UNSIGNED(g, 10) & TO_UNSIGNED(b, 10));
	END c;
	-- white, cyan, green, orange, light red, magenta, yellow, red: the colours of the graph lines
	CONSTANT PAL : colours := (c(950, 950, 950), c(300, 900, 1000), c(500, 1000, 300), c(1000, 600, 100),
		c(900, 350, 350), c(1000, 300, 850), c(1000, 1000, 200), c(1023, 120, 120));

	FUNCTION cv (s : STRING) RETURN codes IS
		VARIABLE r : codes(0 TO s'LENGTH - 1) := (OTHERS => 0);
	BEGIN
		FOR i IN s'RANGE LOOP
			FOR k IN CHARS'RANGE LOOP
				IF CHARS(k) = s(i) THEN
					r(i - s'LOW) := k - CHARS'LOW;
				END IF;
			END LOOP;
		END LOOP;
		RETURN r;
	END cv;

	FUNCTION fixed RETURN cells IS
		VARIABLE m : cells := (OTHERS => 0);
		PROCEDURE put (h, x, k : INTEGER; s : STRING) IS
			VARIABLE r : codes(0 TO s'LENGTH - 1);
		BEGIN
			r := cv(s);
			FOR i IN r'RANGE LOOP
				m(h * 40 + x + i) := r(i) + 128 * k;
				m(h * 40 + 40 + x + i) := r(i) + 64 + 128 * k;
			END LOOP;
		END put;
	BEGIN
		put(2, 0, 0, "H3.3s GFM10% P0 0.9pu R1GW");
		put(8, 0, 0, "F(Hz)");
		put(8, 7, 1, "F");
		put(8, 10, 0, "REF59.2");
		put(8, 19, 4, "UFLS LEVEL");
		put(11, 1, 0, "61.0");
		put(14, 1, 0, "60.0");
		put(19, 1, 0, "59.0");
		put(23, 1, 0, "58.0");
		put(28, 0, 0, "I1(pu)");
		put(28, 8, 2, "I1");
		put(28, 12, 3, "IMAX");
		put(30, 2, 0, "2.0");
		put(37, 2, 0, "1.0");
		put(45, 2, 0, "0.0");
		put(47, 1, 0, "LIM");
		put(50, 0, 0, "AGE(s)");
		put(50, 6, 0, "-20.97");
		put(50, 14, 0, "-15");
		put(50, 21, 0, "-10");
		put(50, 29, 0, "-5");
		put(50, 35, 0, "NOW");
		put(53, 0, 5, "TRIP");
		put(53, 6, 3, "STEP");
		put(53, 12, 7, "UFLS");
		RETURN m;
	END fixed;
	CONSTANT ROM : cells := fixed;

	FUNCTION fixed2 RETURN cells IS                     -- the comparison view
		VARIABLE m : cells := (OTHERS => 0);
		PROCEDURE put (h, x, k : INTEGER; s : STRING) IS
			VARIABLE r : codes(0 TO s'LENGTH - 1);
		BEGIN
			r := cv(s);
			FOR i IN r'RANGE LOOP
				m(h * 40 + x + i) := r(i) + 128 * k;
				m(h * 40 + 40 + x + i) := r(i) + 64 + 128 * k;
			END LOOP;
		END put;
	BEGIN
		put(2, 5, 0, "F(Hz) MIN(Hz)   SH(GW) PK(pu) T(s)");
		put(8, 0, 0, "F(Hz)");
		put(8, 7, 1, "F");
		put(8, 9, 6, "PREV");
		put(8, 14, 0, "REF59.2");
		put(8, 22, 4, "UFLS LEVEL");
		put(11, 1, 0, "61.0");
		put(14, 1, 0, "60.0");
		put(19, 1, 0, "59.0");
		put(23, 1, 0, "58.0");
		put(28, 0, 0, "I1(pu)");
		put(28, 8, 2, "I1");
		put(28, 11, 6, "PREV");
		put(28, 16, 3, "IMAX(NOW)");
		put(30, 2, 0, "2.0");
		put(37, 2, 0, "1.0");
		put(45, 2, 0, "0.0");
		put(47, 1, 0, "LIM");
		put(49, 0, 0, "RESET 0      5      10      15     20.97");
		put(51, 0, 5, "TRIP");
		put(51, 6, 3, "STEP");
		put(51, 12, 7, "UFLS");
		put(51, 18, 0, "T: S AFTER TRIP");
		put(57, 0, 0, "H3.3s GFM10% P0 0.9pu R1GW");
		RETURN m;
	END fixed2;
	CONSTANT ROM2 : cells := fixed2;

	FUNCTION run (f, a : STD_LOGIC) RETURN codes IS       -- 11 cells
	BEGIN
		IF a = '1' AND f = '1' THEN
			RETURN cv("A1.4GW FB  ");
		ELSIF a = '1' THEN
			RETURN cv("A1.4GW SAT ");
		ELSIF f = '1' THEN
			RETURN cv("B3.3GW FB  ");
		END IF;
		RETURN cv("B3.3GW SAT ");
	END run;

	FUNCTION limit (m : INTEGER; h : STD_LOGIC) RETURN codes IS     -- 10 cells
	BEGIN
		IF m = 0 THEN
			RETURN cv("1.2pu     ");
		ELSIF m = 2 THEN
			RETURN cv("NOLIM     ");
		ELSIF h = '1' THEN
			RETURN cv("SPEC 1.0pu");
		END IF;
		RETURN cv("SPEC 1.2pu");
	END limit;

	FUNCTION model (m, v : STD_LOGIC) RETURN codes IS    -- 6 cells
	BEGIN
		IF m = '0' THEN
			RETURN cv("AVG   ");
		ELSIF v = '1' THEN
			RETURN cv("PWM4.0");
		END IF;
		RETURN cv("PWM2.4");
	END model;

	-- four HEX digits as dd.dd, or ERR, or dashes when not shown
	FUNCTION num (v : STD_LOGIC_VECTOR(15 DOWNTO 0); bad, show : STD_LOGIC) RETURN codes IS
	BEGIN
		IF show = '0' THEN
			RETURN cv("--.--");
		ELSIF bad = '1' THEN
			RETURN cv(" ERR ");
		END IF;
		RETURN (1 + TO_INTEGER(UNSIGNED(v(15 DOWNTO 12))), 1 + TO_INTEGER(UNSIGNED(v(11 DOWNTO 8))), cv(".")(0),
			1 + TO_INTEGER(UNSIGNED(v(7 DOWNTO 4))), 1 + TO_INTEGER(UNSIGNED(v(3 DOWNTO 0))));
	END num;

	FUNCTION pk (v : STD_LOGIC_VECTOR(15 DOWNTO 0); bad, show : STD_LOGIC) RETURN codes IS   -- d.ddd
	BEGIN
		IF show = '0' THEN
			RETURN cv("-.---");
		ELSIF bad = '1' THEN
			RETURN cv(" ERR ");
		END IF;
		RETURN (1 + TO_INTEGER(UNSIGNED(v(15 DOWNTO 12))), cv(".")(0), 1 + TO_INTEGER(UNSIGNED(v(11 DOWNTO 8))),
			1 + TO_INTEGER(UNSIGNED(v(7 DOWNTO 4))), 1 + TO_INTEGER(UNSIGNED(v(3 DOWNTO 0))));
	END pk;

	-- a table row: F, lowest F, OK / LOW, shed, PK, T (lowest F and its flag, PK and T only after the trip)
	FUNCTION row (s : STRING; w : shown; g : STD_LOGIC) RETURN codes IS
		VARIABLE r : codes(0 TO 39) := (OTHERS => 0);
	BEGIN
		r(0 TO 3) := cv(s);
		r(5 TO 9) := num(w.dd(15 DOWNTO 0), w.db(0), '1');
		r(11 TO 15) := num(w.dd(31 DOWNTO 16), w.db(1), w.dt);
		IF w.dt = '1' AND g = '1' THEN
			r(17 TO 19) := cv(" OK");
		ELSIF w.dt = '1' THEN
			r(17 TO 19) := cv("LOW");
		END IF;
		r(21 TO 25) := num(w.dd(47 DOWNTO 32), w.db(2), '1');
		r(28 TO 32) := pk(w.dd(79 DOWNTO 64), w.db(4), w.dt);
		r(35 TO 39) := num(w.dd(63 DOWNTO 48), w.db(3), w.dt);
		RETURN r;
	END row;

	FUNCTION good (x : SIGNED; a : STD_LOGIC) RETURN STD_LOGIC IS    -- MIN at or above the reference
	BEGIN
		IF (a = '1' AND x >= -10737418) OR (a = '0' AND x >= -28633115) THEN
			RETURN '1';
		END IF;
		RETURN '0';
	END good;

	SIGNAL l0, l4, l6, l53, l55 : codes(0 TO 39) := (OTHERS => 0);
	SIGNAL cvv, okp, same : STD_LOGIC := '0';
	SIGNAL lp : codes(0 TO 9) := (OTHERS => 0);
	SIGNAL lv : codes(0 TO 11) := (OTHERS => 0);
	SIGNAL ok, rf : STD_LOGIC := '0';
	SIGNAL ad : INTEGER RANGE 0 TO 2399 := 0;
	SIGNAL tq, tq2 : INTEGER RANGE 0 TO 1023;
	SIGNAL h1 : INTEGER RANGE 0 TO 65;
	SIGNAL c1 : INTEGER RANGE 0 TO 49;
	SIGNAL f1, f2 : INTEGER RANGE 0 TO 7;
	SIGNAL r1 : INTEGER RANGE 0 TO 3;
	SIGNAL v1, v2 : BOOLEAN := FALSE;
	SIGNAL fa : INTEGER RANGE 0 TO 383 := 0;
	SIGNAL fq : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL k2 : INTEGER RANGE 0 TO 7;
BEGIN
	ton <= fq(7 - f2) WHEN v2 ELSE '0';
	tc <= PAL(k2);

	PROCESS (clk)                                       -- the two ROMs, read every clock
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			tq <= ROM(ad);
			tq2 <= ROM2(ad);
			fq <= FONT(fa);
		END IF;
	END PROCESS;

	PROCESS (clk)
		VARIABLE k, h, cl : INTEGER;
		VARIABLE st : codes(0 TO 11);
		VARIABLE lw : codes(0 TO 39);
		VARIABLE pv5 : codes(0 TO 9);
		VARIABLE t : INTEGER RANGE 0 TO 1023;
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			IF vb = '1' THEN                             -- vertical blank: the text of the next frame
				IF lm = 3 THEN
					st := cv("INVALID     ");
				ELSIF bz = '1' THEN
					st := cv("STEP        ");
				ELSIF ps = '1' THEN
					st := cv("PAUSE       ");
				ELSIF tr = '1' AND au = '1' THEN
					st := cv("TRIP AUTO   ");
				ELSIF tr = '1' THEN
					st := cv("TRIP KEY1   ");
				ELSIF au = '1' THEN
					st := cv("READY AUTO1s");
				ELSE
					st := cv("READY KEY1  ");
				END IF;
				IF lm /= 3 AND bz = '0' AND ps = '0' AND sl > 0 THEN
					st := cv("READY       ");
					IF tr = '1' THEN
						st := cv("TRIP        ");
					END IF;
					IF sl = 1 THEN
						st(6 TO 8) := cv("1:4");
					ELSIF sl = 2 THEN
						st(6 TO 9) := cv("1:10");
					ELSE
						st(6 TO 10) := cv("1:100");
					END IF;
				END IF;
				lw := run(fb, ta) & limit(lm, sh) & cv("       ") & st;
				IF cmp = '1' THEN
					lw(22 TO 27) := model(md, vs);
				END IF;
				IF lm = 3 THEN
					lw := cv("SW2:1=11 INVALID") & cv("            ") & st;
				END IF;
				l0 <= lw;
				ok <= dt AND good(lo, ta);
				okp <= pv.dt AND good(pv.lo, pv.st(4));
				cvv <= cmp;
				IF cmp = '1' THEN
					l4 <= row("NOW ", (dd, db, dt, lo, (OTHERS => '0'), '1'), good(lo, ta));
					l6 <= cv("PREV ----") & cv("                               ");
					IF pv.ok = '1' THEN
						l6 <= row("PREV", pv, good(pv.lo, pv.st(4)));
					END IF;
				ELSE
					lw := cv("F ") & num(dd(15 DOWNTO 0), db(0), '1') & cv("Hz           MIN ")
						& num(dd(31 DOWNTO 16), db(1), dt) & cv("Hz    ") & cv("     ");
					IF dt = '1' AND good(lo, ta) = '1' THEN
						lw(32 TO 34) := cv(" OK");
					ELSIF dt = '1' THEN
						lw(32 TO 34) := cv("LOW");
					END IF;
					l4 <= lw;
					l6 <= cv("SHED ") & num(dd(47 DOWNTO 32), db(2), '1') & cv("GW        T ")
						& num(dd(63 DOWNTO 48), db(3), dt) & cv("s            ");
				END IF;
				l53 <= cv("PREV ----") & cv("                               ");
				l55 <= (OTHERS => 0);
				same <= '0';
				IF pv.ok = '1' THEN
					lw := cv("PREV ") & run(pv.st(7), pv.st(4)) & limit(TO_INTEGER(UNSIGNED(pv.st(6 DOWNTO 5))),
						pv.st(0)) & cv(" ") & model(pv.st(2), pv.st(1)) & cv(" KEY1  ");
					IF pv.st(3) = '1' THEN
						lw(34 TO 37) := cv("AUTO");
					END IF;
					l53 <= lw;
					IF au = '0' OR pv.st(3) = '0' THEN
						l55 <= cv("MANUAL TIMING") & cv("                           ");
					ELSIF pv.st(6 DOWNTO 1) /= STD_LOGIC_VECTOR(TO_UNSIGNED(lm, 2)) & ta & au & md & vs THEN
						l55 <= cv("DIFF SETUP") & cv("                              ");
					ELSIF pv.st(7) = fb THEN
						l55 <= cv("SAME SETUP") & cv("                              ");
						same <= '1';
					ELSE
						l55 <= cv("SAME SETUP EXCEPT SAT VS FB") & cv("             ");
						same <= '1';
					END IF;
				END IF;
				rf <= ta;
				pv5 := cv("PK -.---pu");                   -- d.ddd from four digits in 0.001 pu
				IF dt = '1' AND db(4) = '1' THEN
					pv5 := cv("PK  ERR pu");
				ELSIF dt = '1' THEN
					pv5(3 TO 7) := pk(dd(79 DOWNTO 64), '0', '1');
				END IF;
				lp <= pv5;
				lv <= cv("AVG VDC -.- ");
				IF md = '1' AND vs = '1' THEN
					lv <= cv("PWM VDC4.0pu");
				ELSIF md = '1' THEN
					lv <= cv("PWM VDC2.4pu");
				END IF;
			END IF;

			IF pe = '1' THEN
				h := vc / 8;                             -- stage 1
				ad <= (h MOD 60) * 40 + hc / 16 MOD 40;
				h1 <= h;
				c1 <= hc / 16;
				f1 <= hc MOD 16 / 2;
				r1 <= vc MOD 8 / 2;
				v1 <= hc < 640 AND vc < 480;

				cl := 0;                                 -- stage 2: tq, tq2 are the ROM cells of stage 1
				t := tq;
				IF cvv = '1' THEN
					t := tq2;
				END IF;
				IF h1 <= 1 OR (h1 >= 4 AND h1 <= 7) THEN
					IF h1 <= 1 THEN
						k := l0(c1 MOD 40);
					ELSIF h1 <= 5 THEN
						k := l4(c1 MOD 40);
						IF (cvv = '0' AND c1 >= 32 AND c1 <= 34) OR (cvv = '1' AND c1 >= 17 AND c1 <= 19) THEN
							cl := 7;
							IF ok = '1' THEN
								cl := 2;
							END IF;
						END IF;
					ELSE
						k := l6(c1 MOD 40);
						IF cvv = '1' AND c1 <= 3 THEN
							cl := 6;
						ELSIF cvv = '1' AND c1 >= 17 AND c1 <= 19 THEN
							cl := 7;
							IF okp = '1' THEN
								cl := 2;
							END IF;
						END IF;
					END IF;
					fa <= k * 8 + (h1 MOD 2) * 4 + r1;
				ELSE
					k := t MOD 64;
					IF (h1 = 8 OR h1 = 9) AND rf = '1' AND ((cvv = '0' AND c1 = 16) OR (cvv = '1' AND c1 = 20)) THEN
						k := cv("7")(0);
					END IF;
					cl := t / 128;
					fa <= k * 8 + (t / 64 MOD 2) * 4 + r1;
					IF cvv = '0' AND (h1 = 28 OR h1 = 29) AND c1 >= 20 AND c1 <= 29 THEN
						k := lp(c1 - 20);
						cl := 2;
						fa <= k * 8 + (h1 MOD 2) * 4 + r1;
					END IF;
					IF cvv = '0' AND (h1 = 2 OR h1 = 3) AND c1 >= 28 AND c1 <= 39 THEN
						k := lv(c1 - 28);
						cl := 0;
						fa <= k * 8 + (h1 MOD 2) * 4 + r1;
					END IF;
					IF cvv = '1' AND h1 >= 53 AND h1 <= 56 THEN
						k := l55(c1 MOD 40);
						cl := 3;
						IF same = '1' THEN
							cl := 2;
						END IF;
						IF h1 <= 54 THEN
							k := l53(c1 MOD 40);
							cl := 0;
							IF c1 <= 3 THEN
								cl := 6;
							END IF;
						END IF;
						fa <= k * 8 + ((h1 + 1) MOD 2) * 4 + r1;      -- these lines start on odd half rows
					END IF;
				END IF;
				k2 <= cl;
				f2 <= f1;
				v2 <= v1 AND k /= 0;
			END IF;
		END IF;
	END PROCESS;
END a;
