LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- Graph recorder: one column for every nk model steps (40,960 = 40 grid updates = 40.96 ms) into a
-- 512-column ring, already turned into screen rows so the drawing side only compares.
--   column word: 6..0 frequency top row, 13..7 frequency bottom row, 14 above the graph, 15 below it,
--   22..16 |i1| top row, 29..23 |i1| bottom row, 30 |i1| above 2 pu, 37..31 Imax row, 38 Imax shown,
--   39 limiter acted, 40 trip, 41 1.0 pu limit started, 42 load shed grew
--   frequency rows: 34 - floor(x 2^11) (1 row = 2^-11 pu, 60 Hz on row 34, 61.0 Hz on row 0), kept
--   inside 0..127 with the flags; current rows: 127 - floor(64 |i1|) from the column's highest and
--   lowest i1^2; floor(64 |i1|) = floor(sqrt(i1^2 / 2^16)) in Q28, found bit by bit (7 trial squares)
--   A finished column waits in pd and goes into the ring on the next vb (vertical blank), together with
--   the write address wp and the count of written columns nv, so nothing the screen reads changes while
--   a frame is drawn. A column takes 40.96 ms and a frame 16.8 ms, so at most one column waits.
--   load (reset, power-up or the reserved limit mode) clears the column being collected, the waiting
--   column, wp and nv, and wins over a write on the same clock. The ring itself is not cleared: columns
--   older than nv are not drawn.
-- After each step: j = 1 squares i1, 2 keeps the lowest and highest i1^2; at the end of a column 3, 4
-- take the root of the highest (7 clocks), 5, 6 of the lowest, 7 packs the word: 19 clocks of the 50.
ENTITY rec IS
	GENERIC (nk : INTEGER := 40960);
	PORT (clk, load, step, vb : IN STD_LOGIC;
		x, ir, ii, shed, imx : IN SIGNED(31 DOWNTO 0);   -- x, shed Q31; i1, Imax Q28
		lim, en, tr, sh : IN STD_LOGIC;
		ra  : IN UNSIGNED(8 DOWNTO 0);
		q   : OUT STD_LOGIC_VECTOR(42 DOWNTO 0);
		wp  : BUFFER UNSIGNED(8 DOWNTO 0);
		nv  : BUFFER INTEGER RANGE 0 TO 512);
END rec;

ARCHITECTURE a OF rec IS
	TYPE ring IS ARRAY (0 TO 511) OF STD_LOGIC_VECTOR(42 DOWNTO 0);
	SIGNAL mem : ring;
	SIGNAL pd : STD_LOGIC_VECTOR(42 DOWNTO 0);
	SIGNAL ev : STD_LOGIC_VECTOR(3 DOWNTO 0);            -- shed, 1.0 pu, trip, limiter
	SIGNAL ih : STD_LOGIC_VECTOR(7 DOWNTO 0);            -- above flag and top row of |i1|
	SIGNAL pv, nw, tp, sp : STD_LOGIC := '0';
	SIGNAL n : INTEGER RANGE 0 TO nk - 1 := 0;
	SIGNAL j : INTEGER RANGE 0 TO 7 := 0;
	SIGNAL bt : INTEGER RANGE 0 TO 6 := 0;
	SIGNAL xl, xh, s0 : SIGNED(31 DOWNTO 0);
	SIGNAL a, b : SIGNED(17 DOWNTO 0);
	SIGNAL m, ml, mh : UNSIGNED(36 DOWNTO 0);
	SIGNAL r : UNSIGNED(20 DOWNTO 0);
	SIGNAL p : UNSIGNED(6 DOWNTO 0);

	FUNCTION frow (v : SIGNED) RETURN STD_LOGIC_VECTOR IS   -- below, above, row
		VARIABLE k : INTEGER;
	BEGIN
		k := 34 - TO_INTEGER(SHIFT_RIGHT(v, 20));
		IF k < 0 THEN
			RETURN "010000000";
		ELSIF k > 127 THEN
			RETURN "101111111";
		END IF;
		RETURN "00" & STD_LOGIC_VECTOR(TO_UNSIGNED(k, 7));
	END frow;

	FUNCTION irow (v, k : UNSIGNED) RETURN STD_LOGIC_VECTOR IS      -- above, row (v = i1^2 / 2^16)
	BEGIN
		IF v >= 16384 THEN
			RETURN "10000000";
		END IF;
		RETURN '0' & STD_LOGIC_VECTOR(127 - k);
	END irow;
BEGIN
	PROCESS (clk)                                       -- the ring: written only in vertical blank
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			IF pv = '1' AND vb = '1' AND load = '0' THEN
				mem(TO_INTEGER(wp)) <= pd;
			END IF;
			q <= mem(TO_INTEGER(ra));
		END IF;
	END PROCESS;

	PROCESS (clk)
		VARIABLE t : UNSIGNED(6 DOWNTO 0);
		VARIABLE fh, fl : STD_LOGIC_VECTOR(8 DOWNTO 0);
		VARIABLE il : STD_LOGIC_VECTOR(7 DOWNTO 0);
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			IF load = '1' THEN
				n <= 0;
				j <= 0;
				nw <= '1';
				pv <= '0';
				wp <= (OTHERS => '0');
				nv <= 0;
				ev <= "0000";
				tp <= '0';
				sp <= '0';
				s0 <= (OTHERS => '0');
			ELSE
				IF pv = '1' AND vb = '1' THEN
					pv <= '0';
					wp <= wp + 1;
					IF nv < 512 THEN
						nv <= nv + 1;
					END IF;
				END IF;
				IF step = '1' THEN                     -- x, i1 and the records of the step that ends
					a <= ir(31 DOWNTO 14);              -- Q14, the full +-8 pu range in 18 bits
					b <= ii(31 DOWNTO 14);
					IF nw = '1' OR x < xl THEN
						xl <= x;
					END IF;
					IF nw = '1' OR x > xh THEN
						xh <= x;
					END IF;
					ev <= ev OR ('0' & (sh AND NOT sp) & (tr AND NOT tp) & lim);
					IF shed /= s0 THEN
						ev(3) <= '1';
					END IF;
					tp <= tr;
					sp <= sh;
					s0 <= shed;
					j <= 1;
				ELSIF j = 1 THEN
					m <= UNSIGNED(RESIZE(a * a, 37) + RESIZE(b * b, 37));
					j <= 2;
				ELSIF j = 2 THEN
					IF nw = '1' OR m < ml THEN
						ml <= m;
					END IF;
					IF nw = '1' OR m > mh THEN
						mh <= m;
					END IF;
					nw <= '0';
					j <= 0;
					IF n = nk - 1 THEN
						n <= 0;
						j <= 3;
					ELSE
						n <= n + 1;
					END IF;
				ELSIF j = 3 OR j = 5 THEN                -- start a root: the highest i1^2, then the lowest
					IF j = 3 THEN
						r <= mh(36 DOWNTO 16);
					ELSE
						ih <= irow(r, p);
						r <= ml(36 DOWNTO 16);
					END IF;
					p <= (OTHERS => '0');
					bt <= 6;
					j <= j + 1;
				ELSIF j = 4 OR j = 6 THEN                -- one bit per clock: keep it if the square fits
					t := p;
					t(bt) := '1';
					IF t * t <= r THEN
						p <= t;
					END IF;
					IF bt = 0 THEN
						j <= j + 1;
					ELSE
						bt <= bt - 1;
					END IF;
				ELSIF j = 7 THEN                         -- pack the column
					fh := frow(xh);
					fl := frow(xl);
					il := irow(r, p);
					pd <= ev & en & STD_LOGIC_VECTOR(127 - UNSIGNED(imx(28 DOWNTO 22))) & ih(7) & il(6 DOWNTO 0)
						& ih(6 DOWNTO 0) & fl(8) & fh(7) & fl(6 DOWNTO 0) & fh(6 DOWNTO 0);
					pv <= '1';
					nw <= '1';
					ev <= "0000";
					j <= 0;
				END IF;
			END IF;
		END IF;
	END PROCESS;
END a;
