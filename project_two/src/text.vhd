LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- Text over the graphs, 16 x 16 pixels per character (the 8 x 8 font doubled), 40 columns. Text lines
-- start on any multiple of 8 pixels, so the screen is 60 half rows of 8 pixels; a character fills two.
--   fixed text (labels, axis numbers, legend) is a ROM of 60 x 40 cells built when the design is
--   elaborated: character number, which half, colour
--   half rows 0..1, 4..5 and 6..7 are rebuilt in vertical blank from the settings and the HEX values:
--   settings and state, F and MIN with OK or LOW, SHED and T. The legend's reference digit (59.2 or
--   59.7 Hz) follows the trip type. All inputs are taken in vertical blank, so a frame shows one copy.
--   dd, db, dt, lo come from the HEX display buffer: digits (value v digit i at 16 v + 4 i, values f,
--   lowest f, shed, time), out-of-range flags, the trip flag and the lowest x of the same copy.
--   MIN OK: the lowest x (not the rounded digits) is at or above 59.7 Hz for trip A, 59.2 Hz for trip B
--   (-0.3/60 and -0.8/60 pu in Q31, rounded up). LOW once below.
--   pipeline (one stage per pixel clock, as in scope): 1 ROM address, 2 character and font address,
--   3 font row read: ton and tc are ready for the third stage.
ENTITY text IS
	PORT (clk, pe, vb, ta, fb, sh, au, tr, dt : IN STD_LOGIC;
		hc  : IN INTEGER RANGE 0 TO 799;
		vc  : IN INTEGER RANGE 0 TO 524;
		lm  : IN INTEGER RANGE 0 TO 3;
		dd  : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
		db  : IN STD_LOGIC_VECTOR(0 TO 3);
		lo  : IN SIGNED(31 DOWNTO 0);
		ton : OUT STD_LOGIC;
		tc  : OUT STD_LOGIC_VECTOR(29 DOWNTO 0));
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
		put(53, 12, 6, "UFLS");
		RETURN m;
	END fixed;
	CONSTANT ROM : cells := fixed;

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

	SIGNAL l0, l4, l6 : codes(0 TO 39) := (OTHERS => 0);
	SIGNAL ok, rf : STD_LOGIC := '0';
	SIGNAL ad : INTEGER RANGE 0 TO 2399 := 0;
	SIGNAL tq : INTEGER RANGE 0 TO 1023;
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
			fq <= FONT(fa);
		END IF;
	END PROCESS;

	PROCESS (clk)
		VARIABLE k, h, cl : INTEGER;
		VARIABLE lim : codes(0 TO 9);
		VARIABLE st : codes(0 TO 11);
		VARIABLE lw : codes(0 TO 39);
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			IF vb = '1' THEN                             -- vertical blank: the text of the next frame
				IF lm = 0 THEN
					lim := cv("1.2pu     ");
				ELSIF lm = 2 THEN
					lim := cv("NOLIM     ");
				ELSIF sh = '1' THEN
					lim := cv("SPEC 1.0pu");
				ELSE
					lim := cv("SPEC 1.2pu");
				END IF;
				IF lm = 3 THEN
					st := cv("INVALID     ");
				ELSIF tr = '1' AND au = '1' THEN
					st := cv("TRIP AUTO   ");
				ELSIF tr = '1' THEN
					st := cv("TRIP KEY1   ");
				ELSIF au = '1' THEN
					st := cv("READY AUTO1s");
				ELSE
					st := cv("READY KEY1  ");
				END IF;
				IF lm = 3 THEN
					l0 <= cv("SW2:1=11 INVALID") & cv("            ") & st;
				ELSIF ta = '1' AND fb = '1' THEN
					l0 <= cv("A1.4GW FB  ") & lim & cv("       ") & st;
				ELSIF ta = '1' THEN
					l0 <= cv("A1.4GW SAT ") & lim & cv("       ") & st;
				ELSIF fb = '1' THEN
					l0 <= cv("B3.3GW FB  ") & lim & cv("       ") & st;
				ELSE
					l0 <= cv("B3.3GW SAT ") & lim & cv("       ") & st;
				END IF;
				lw := cv("F ") & num(dd(15 DOWNTO 0), db(0), '1') & cv("Hz           MIN ")
					& num(dd(31 DOWNTO 16), db(1), dt) & cv("Hz    ") & cv("     ");
				ok <= '0';
				IF dt = '1' AND ((ta = '1' AND lo >= -10737418) OR (ta = '0' AND lo >= -28633115)) THEN
					lw(32 TO 34) := cv(" OK");
					ok <= '1';
				ELSIF dt = '1' THEN
					lw(32 TO 34) := cv("LOW");
				END IF;
				l4 <= lw;
				l6 <= cv("SHED ") & num(dd(47 DOWNTO 32), db(2), '1') & cv("GW        T ")
					& num(dd(63 DOWNTO 48), db(3), dt) & cv("s            ");
				rf <= ta;
			END IF;

			IF pe = '1' THEN
				h := vc / 8;                             -- stage 1
				ad <= (h MOD 60) * 40 + hc / 16 MOD 40;
				h1 <= h;
				c1 <= hc / 16;
				f1 <= hc MOD 16 / 2;
				r1 <= vc MOD 8 / 2;
				v1 <= hc < 640 AND vc < 480;

				cl := 0;                                 -- stage 2: tq is the ROM cell of stage 1
				IF h1 <= 1 OR (h1 >= 4 AND h1 <= 7) THEN
					IF h1 <= 1 THEN
						k := l0(c1 MOD 40);
					ELSIF h1 <= 5 THEN
						k := l4(c1 MOD 40);
						IF c1 >= 32 AND c1 <= 34 THEN
							cl := 7;
							IF ok = '1' THEN
								cl := 2;
							END IF;
						END IF;
					ELSE
						k := l6(c1 MOD 40);
					END IF;
					fa <= k * 8 + (h1 MOD 2) * 4 + r1;
				ELSE
					k := tq MOD 64;
					IF (h1 = 8 OR h1 = 9) AND c1 = 16 AND rf = '1' THEN
						k := cv("7")(0);
					END IF;
					cl := tq / 128;
					fa <= k * 8 + (tq / 64 MOD 2) * 4 + r1;
				END IF;
				k2 <= cl;
				f2 <= f1;
				v2 <= v1 AND k /= 0;
			END IF;
		END IF;
	END PROCESS;
END a;
