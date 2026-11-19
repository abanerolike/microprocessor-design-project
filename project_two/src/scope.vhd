LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Graphs from the recorder ring: frequency (x 96..607, y 88..215), |i1| with Imax (y 240..367) and the
-- limiter band (y 376..383). Screen column c = x - 96 reads ring address wp + c (mod 512), so the newest
-- column is always on the right; columns with c < 512 - nv are older than the last reset: empty.
--   lines (back to front): frame and grid (60 Hz, 1.0 pu, every 5 s from the right edge), UFLS levels
--   59.0 and 58.0 Hz (dashed), reference 59.7 Hz for trip A or 59.2 Hz for trip B (thick dashes), Imax
--   (dashes), trip and 1.0 pu start (dotted columns), load shed (tick at the top), then the data as one
--   vertical bar per column from its lowest to its highest value, and red at the edge row when the
--   column went past the graph
--   pipeline, one stage per pixel clock: 1 ring address, 2 colour from the ring word, 3 output (text on top)
ENTITY scope IS
	PORT (clk, pe, ta, ton : IN STD_LOGIC;           -- ton, tc: text pixel for the output stage
		hc  : IN INTEGER RANGE 0 TO 799;
		vc  : IN INTEGER RANGE 0 TO 524;
		wp  : IN UNSIGNED(8 DOWNTO 0);
		nv  : IN INTEGER RANGE 0 TO 512;
		q   : IN STD_LOGIC_VECTOR(42 DOWNTO 0);
		tc  : IN STD_LOGIC_VECTOR(29 DOWNTO 0);
		ra  : OUT UNSIGNED(8 DOWNTO 0);
		rgb : OUT STD_LOGIC_VECTOR(29 DOWNTO 0));       -- red, green, blue, 10 bits each
END scope;

ARCHITECTURE a OF scope IS
	FUNCTION c (r, g, b : INTEGER) RETURN STD_LOGIC_VECTOR IS
	BEGIN
		RETURN STD_LOGIC_VECTOR(TO_UNSIGNED(r, 10) & TO_UNSIGNED(g, 10) & TO_UNSIGNED(b, 10));
	END c;

	FUNCTION frow (v : INTEGER) RETURN INTEGER IS         -- same rows as the recorder
	BEGIN
		RETURN 34 - TO_INTEGER(SHIFT_RIGHT(TO_SIGNED(v, 32), 20));
	END frow;

	CONSTANT BLACK : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(0, 0, 0);
	CONSTANT DARK  : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(160, 160, 160);
	CONSTANT GREY  : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(420, 420, 420);
	CONSTANT CYAN  : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(300, 900, 1000);
	CONSTANT GREEN : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(500, 1000, 300);
	CONSTANT ORNG  : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(1000, 600, 100);
	CONSTANT WHITE : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(950, 950, 950);
	CONSTANT DRED  : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(600, 160, 160);
	CONSTANT RED   : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(1023, 120, 120);
	CONSTANT MAGEN : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(1000, 300, 850);
	CONSTANT YELLW : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(1000, 1000, 200);
	CONSTANT PINK  : STD_LOGIC_VECTOR(29 DOWNTO 0) := c(900, 450, 450);
	CONSTANT U1 : INTEGER := frow(THR(0));                -- 59.0 Hz, row 69
	CONSTANT U6 : INTEGER := frow(THR(5));                -- 58.0 Hz, row 103
	CONSTANT RFA : INTEGER := frow(-10737418);             -- 59.7 Hz (-0.3/60 pu), row 45
	CONSTANT RFB : INTEGER := frow(-28633115);             -- 59.2 Hz (-0.8/60 pu), row 62

	SIGNAL x1 : INTEGER RANGE 0 TO 799;
	SIGNAL y1 : INTEGER RANGE 0 TO 524;
	SIGNAL col : STD_LOGIC_VECTOR(29 DOWNTO 0);
BEGIN
	PROCESS (clk)
		VARIABLE k, r, rf : INTEGER;
		VARIABLE ok : BOOLEAN;
		VARIABLE v : STD_LOGIC_VECTOR(29 DOWNTO 0);
	BEGIN
		IF clk = '1' AND clk'EVENT AND pe = '1' THEN
			ra <= wp + TO_UNSIGNED((hc + 416) MOD 512, 9);    -- hc - 96 mod 512
			x1 <= hc;
			y1 <= vc;
			rgb <= col;
			IF ton = '1' THEN
				rgb <= tc;                               -- text over the graphs
			END IF;

			k := x1 - 96;                                    -- screen column, valid in 0..511
			ok := k >= 512 - nv AND k <= 511;
			rf := RFB;
			IF ta = '1' THEN
				rf := RFA;
			END IF;
			v := BLACK;
			IF y1 >= 88 AND y1 <= 215 AND x1 >= 95 AND x1 <= 607 THEN
				r := y1 - 88;
				IF x1 = 95 OR r = 34 OR k = 145 OR k = 267 OR k = 389 THEN
					v := DARK;
				END IF;
				IF (r = U1 OR r = U6) AND x1 MOD 4 < 2 THEN
					v := DRED;
				END IF;
				IF (r = rf - 1 OR r = rf) AND x1 MOD 8 < 5 THEN
					v := WHITE;
				END IF;
				IF ok AND q(41) = '1' AND y1 MOD 4 < 2 THEN
					v := ORNG;
				END IF;
				IF ok AND q(40) = '1' AND y1 MOD 4 < 2 THEN
					v := MAGEN;
				END IF;
				IF ok AND q(42) = '1' AND r < 6 THEN
					v := YELLW;
				END IF;
				IF ok AND r >= TO_INTEGER(UNSIGNED(q(6 DOWNTO 0))) AND r <= TO_INTEGER(UNSIGNED(q(13 DOWNTO 7))) THEN
					v := CYAN;
				END IF;
				IF ok AND ((q(14) = '1' AND r = 0) OR (q(15) = '1' AND r = 127)) THEN
					v := RED;
				END IF;
			ELSIF y1 >= 240 AND y1 <= 367 AND x1 >= 95 AND x1 <= 607 THEN
				r := y1 - 240;
				IF x1 = 95 OR r = 63 OR k = 145 OR k = 267 OR k = 389 THEN
					v := DARK;
				END IF;
				IF ok AND q(38) = '1' AND r = TO_INTEGER(UNSIGNED(q(37 DOWNTO 31))) AND x1 MOD 8 < 6 THEN
					v := ORNG;
				END IF;
				IF ok AND q(41) = '1' AND y1 MOD 4 < 2 THEN
					v := ORNG;
				END IF;
				IF ok AND q(40) = '1' AND y1 MOD 4 < 2 THEN
					v := MAGEN;
				END IF;
				IF ok AND r >= TO_INTEGER(UNSIGNED(q(22 DOWNTO 16))) AND r <= TO_INTEGER(UNSIGNED(q(29 DOWNTO 23))) THEN
					v := GREEN;
				END IF;
				IF ok AND q(30) = '1' AND r = 0 THEN
					v := RED;
				END IF;
			ELSIF (y1 = 216 OR y1 = 368) AND x1 >= 95 AND x1 <= 607 THEN
				v := GREY;
			ELSIF y1 >= 376 AND y1 <= 383 AND ok THEN
				v := DARK;
				IF q(39) = '1' THEN
					v := PINK;
				END IF;
			END IF;
			col <= v;
		END IF;
	END PROCESS;
END a;
