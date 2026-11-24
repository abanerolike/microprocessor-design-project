LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- Graph drawing, checked on the screen the DAC would show: one frame is captured on the rising edge of
-- ck while bl is high, with the timing generator driving the drawing, so the pipeline delay is part of
-- the test. A test ring (one-clock read like the M4K) holds words built from their own address.
--   wp = 100, nv = 300: columns 0..211 empty, column c shows ring address (100 + c) mod 512
--   frequency bar on rows top..top + 20 with top = address mod 90; |i1| bar rows 40..70; Imax row 30
--   at even addresses; limiter on odd addresses; trip, 1.0 pu and shed records at one address each;
--   above and below flags at one address each
--   reference rows 44..45 for trip A and 61..62 for trip B (two frames), UFLS rows 69 and 103, 60 Hz row
--   34, frame line at x 95 and y 216, 368
--   comparison view (third frame, nv = 300, np = 400): column c reads address c; a previous-run ring
--   with its own bars (frequency rows (c + 10) mod 90 .. + 10, inside the current bar, |i1| rows 80..90) and a trip at 350:
--   both runs on a pixel: even x current, odd x previous where (x + r) mod 4 < 2; only the previous run:
--   yellow dashes; its trip as a yellow tick on rows 122..127; grid every 5 s from the left (122, 244,
--   366, 488)
ENTITY scope_tb IS
END scope_tb;

ARCHITECTURE a OF scope_tb IS
	TYPE ring IS ARRAY (0 TO 511) OF STD_LOGIC_VECTOR(42 DOWNTO 0);
	TYPE shot IS ARRAY (0 TO 639, 0 TO 479) OF INTEGER RANGE 0 TO 15;
	SIGNAL clk, pe, vb, ck, hs, vs, bl, ta : STD_LOGIC := '0';
	SIGNAL hc : INTEGER RANGE 0 TO 799;
	SIGNAL vc : INTEGER RANGE 0 TO 524;
	SIGNAL ra : UNSIGNED(8 DOWNTO 0);
	SIGNAL q : STD_LOGIC_VECTOR(42 DOWNTO 0);
	SIGNAL rgb : STD_LOGIC_VECTOR(29 DOWNTO 0);
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL mem, memp : ring;
	SIGNAL cv : STD_LOGIC := '0';
	SIGNAL qp : STD_LOGIC_VECTOR(42 DOWNTO 0);
	SIGNAL white : STD_LOGIC_VECTOR(29 DOWNTO 0) := (OTHERS => '1');

	FUNCTION c (r, g, b : INTEGER) RETURN STD_LOGIC_VECTOR IS
	BEGIN
		RETURN STD_LOGIC_VECTOR(TO_UNSIGNED(r, 10) & TO_UNSIGNED(g, 10) & TO_UNSIGNED(b, 10));
	END c;

	-- colour names: 0 black, 1 dark, 2 grey, 3 cyan, 4 green, 5 orange, 6 white, 7 dark red, 8 red,
	-- 9 magenta, 10 yellow, 11 pink, 15 anything else
	FUNCTION name (v : STD_LOGIC_VECTOR) RETURN INTEGER IS
	BEGIN
		IF v = c(0, 0, 0) THEN RETURN 0;
		ELSIF v = c(160, 160, 160) THEN RETURN 1;
		ELSIF v = c(420, 420, 420) THEN RETURN 2;
		ELSIF v = c(300, 900, 1000) THEN RETURN 3;
		ELSIF v = c(500, 1000, 300) THEN RETURN 4;
		ELSIF v = c(1000, 600, 100) THEN RETURN 5;
		ELSIF v = c(950, 950, 950) THEN RETURN 6;
		ELSIF v = c(600, 160, 160) THEN RETURN 7;
		ELSIF v = c(1023, 120, 120) THEN RETURN 8;
		ELSIF v = c(1000, 300, 850) THEN RETURN 9;
		ELSIF v = c(1000, 1000, 200) THEN RETURN 10;
		ELSIF v = c(900, 450, 450) THEN RETURN 11;
		END IF;
		RETURN 15;
	END name;

	FUNCTION word (a : INTEGER) RETURN STD_LOGIC_VECTOR IS
		VARIABLE w : STD_LOGIC_VECTOR(42 DOWNTO 0) := (OTHERS => '0');
	BEGIN
		w(6 DOWNTO 0) := STD_LOGIC_VECTOR(TO_UNSIGNED(a MOD 90, 7));
		w(13 DOWNTO 7) := STD_LOGIC_VECTOR(TO_UNSIGNED(a MOD 90 + 20, 7));
		w(22 DOWNTO 16) := STD_LOGIC_VECTOR(TO_UNSIGNED(40, 7));
		w(29 DOWNTO 23) := STD_LOGIC_VECTOR(TO_UNSIGNED(70, 7));
		w(37 DOWNTO 31) := STD_LOGIC_VECTOR(TO_UNSIGNED(30, 7));
		IF a MOD 2 = 0 THEN
			w(38) := '1';
		ELSE
			w(39) := '1';
		END IF;
		w(40) := STD_LOGIC'VAL(BOOLEAN'POS(a = 400) + 2);   -- '0' or '1'
		w(41) := STD_LOGIC'VAL(BOOLEAN'POS(a = 450) + 2);
		w(42) := STD_LOGIC'VAL(BOOLEAN'POS(a = 480) + 2);
		w(14) := STD_LOGIC'VAL(BOOLEAN'POS(a = 360) + 2);
		w(15) := STD_LOGIC'VAL(BOOLEAN'POS(a = 370) + 2);
		w(30) := STD_LOGIC'VAL(BOOLEAN'POS(a = 380) + 2);
		RETURN w;
	END word;

	FUNCTION prev (a : INTEGER) RETURN STD_LOGIC_VECTOR IS
		VARIABLE w : STD_LOGIC_VECTOR(42 DOWNTO 0) := (OTHERS => '0');
	BEGIN
		w(6 DOWNTO 0) := STD_LOGIC_VECTOR(TO_UNSIGNED((a + 10) MOD 90, 7));
		w(13 DOWNTO 7) := STD_LOGIC_VECTOR(TO_UNSIGNED((a + 10) MOD 90 + 10, 7));
		w(22 DOWNTO 16) := STD_LOGIC_VECTOR(TO_UNSIGNED(80, 7));
		w(29 DOWNTO 23) := STD_LOGIC_VECTOR(TO_UNSIGNED(90, 7));
		w(40) := STD_LOGIC'VAL(BOOLEAN'POS(a = 350) + 2);
		RETURN w;
	END prev;
BEGIN
	tm : ENTITY work.vga PORT MAP (clk, pe, hc, vc, vb, ck, hs, vs, bl);
	dut : ENTITY work.scope PORT MAP (clk, pe, ta, '0', hc, vc, "001100100", 300, q, white, ra, rgb, cv,
		qp, 400);

	PROCESS
	BEGIN
		FOR i IN 0 TO 511 LOOP
			mem(i) <= word(i);
			memp(i) <= prev(i);
		END LOOP;
		WHILE NOT done LOOP
			clk <= '0';
			WAIT FOR 10 ns;
			clk <= '1';
			WAIT FOR 10 ns;
		END LOOP;
		WAIT;
	END PROCESS;

	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			q <= mem(TO_INTEGER(ra));
			qp <= memp(TO_INTEGER(ra));
		END IF;
	END PROCESS;

	PROCESS
		VARIABLE s : shot;
		VARIABLE errs, px, ln : INTEGER := 0;
		VARIABLE pbl, pvs : STD_LOGIC := '0';
		VARIABLE a, top, rf, x, tp : INTEGER;
		VARIABLE cur, pre : BOOLEAN;

		PROCEDURE check (ok : BOOLEAN; m : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT m SEVERITY ERROR;
			END IF;
		END check;

		PROCEDURE grab IS                                    -- the next whole frame, after a vs pulse
		BEGIN
			WAIT UNTIL vs = '0';
			WAIT UNTIL vs = '1';
			ln := -1;
			WHILE ln < 479 OR bl = '1' LOOP
				WAIT UNTIL ck = '1' AND ck'EVENT;
				IF bl = '1' AND pbl = '0' THEN
					ln := ln + 1;
					px := 0;
				END IF;
				IF bl = '1' THEN
					s(px, ln) := name(rgb);
					px := px + 1;
				END IF;
				pbl := bl;
			END LOOP;
		END grab;
	BEGIN
		FOR f IN 0 TO 1 LOOP
			ta <= STD_LOGIC'VAL(f + 2);                      -- trip B, then trip A
			grab;
			rf := 61 - 17 * f;                               -- reference rows 61..62 for B, 44..45 for A
			FOR k IN 0 TO 511 LOOP
				a := (100 + k) MOD 512;
				top := a MOD 90;
				IF k < 212 THEN                              -- empty columns: no data, no records
					check(s(96 + k, 88 + top + 1) /= 3 AND s(96 + k, 240 + 50) /= 4 AND s(96 + k, 380) = 0,
						"empty column " & INTEGER'IMAGE(k) & " is drawn");
				ELSE
					IF a /= 360 AND a /= 370 THEN
						check(s(96 + k, 88 + top) = 3 AND s(96 + k, 88 + top + 20) = 3,
							"frequency bar ends wrong in column " & INTEGER'IMAGE(k));
						check(top = 0 OR s(96 + k, 88 + top - 1) /= 3, "frequency bar too long, column " & INTEGER'IMAGE(k));
						check(s(96 + k, 88 + top + 21) /= 3, "frequency bar too long below, column " & INTEGER'IMAGE(k));
					END IF;
					check(s(96 + k, 240 + 40) = 4 AND s(96 + k, 240 + 70) = 4 AND s(96 + k, 240 + 39) /= 4
						AND s(96 + k, 240 + 71) /= 4, "current bar wrong in column " & INTEGER'IMAGE(k));
					check((a MOD 2 = 0 AND (96 + k) MOD 8 < 6) = (s(96 + k, 240 + 30) = 5),
						"Imax line wrong in column " & INTEGER'IMAGE(k));
					check((a MOD 2 = 1) = (s(96 + k, 380) = 11), "limiter band wrong in column " & INTEGER'IMAGE(k));
				END IF;
			END LOOP;
			-- records and flags: trip at address 400 is column 300, 1.0 pu at 450 -> 350, shed 480 -> 380,
			-- above 360 -> 260, below 370 -> 270, |i1| above 380 -> 280
			check(s(96 + 300, 88 + 100) = 9 AND s(96 + 300, 88 + 102) /= 9, "trip column not dotted magenta");
			check(s(96 + 300, 240 + 100) = 9, "trip column missing in the current graph");
			check(s(96 + 350, 88 + 120) = 5 AND s(96 + 350, 88 + 122) /= 5, "1.0 pu column not dotted orange");
			check(s(96 + 380, 88 + 2) = 8 AND s(96 + 380, 88 + 6) /= 8, "shed tick wrong");
			check(s(96 + 260, 88) = 8, "above flag not red on row 0");
			check(s(96 + 270, 88 + 127) = 8, "below flag not red on row 127");
			check(s(96 + 280, 240) = 8, "|i1| above 2 pu not red on row 0");
			-- lines, checked in an empty column (k = 10) so no data hides them
			check(s(96 + 10, 88 + 34) = 1, "60 Hz line missing");
			check(s(96 + 8, 88 + 69) = 7 AND s(96 + 10, 88 + 69) /= 7, "59.0 Hz dashes wrong");
			check(s(96 + 8, 88 + 103) = 7, "58.0 Hz dashes missing");
			check(s(96 + 8, 88 + rf) = 6 AND s(96 + 8, 88 + rf + 1) = 6 AND s(96 + 8, 88 + rf + 2) /= 6
				AND s(96 + 13, 88 + rf) /= 6, "reference line wrong for trip " & INTEGER'IMAGE(f));
			check(s(95, 100) = 1 AND s(300, 216) = 2 AND s(300, 368) = 2 AND s(94, 100) = 0,
				"frame lines wrong");
			check(s(96 + 145, 88 + 10) = 1 AND s(96 + 146, 88 + 10) = 0, "5 s grid line wrong");
			check(s(620, 100) = 0 AND s(50, 300) = 0, "drawing outside the graphs");
		END LOOP;
		cv <= '1';                                           -- comparison view, trip B
		ta <= '0';
		grab;
		FOR k IN 0 TO 511 LOOP
			x := 96 + k;
			top := k MOD 90;
			tp := (k + 10) MOD 90;
			FOR r IN 0 TO 121 LOOP
				cur := k < 300 AND r >= top AND r <= top + 20;
				pre := k < 400 AND r >= tp AND r <= tp + 10 AND (x + r) MOD 4 < 2;
				IF cur AND NOT (pre AND x MOD 2 = 1) THEN
					check(s(x, 88 + r) = 3, "comparison: current bar missing at column " & INTEGER'IMAGE(k)
						& " row " & INTEGER'IMAGE(r));
				ELSIF pre THEN
					check(s(x, 88 + r) = 10, "comparison: previous dash missing at column " & INTEGER'IMAGE(k)
						& " row " & INTEGER'IMAGE(r));
				ELSE
					check(s(x, 88 + r) /= 3 AND s(x, 88 + r) /= 10, "comparison: bar where none is, column "
						& INTEGER'IMAGE(k) & " row " & INTEGER'IMAGE(r));
				END IF;
			END LOOP;
			check((s(x, 240 + 85) = 10) = (k < 400 AND (x + 85) MOD 4 < 2) AND (s(x, 240 + 50) = 4) = (k < 300),
				"comparison: |i1| bars wrong at column " & INTEGER'IMAGE(k));
		END LOOP;
		check(s(96 + 350, 88 + 122) = 10 AND s(96 + 350, 88 + 127) = 10 AND s(96 + 351, 88 + 125) /= 10,
			"previous trip tick wrong");
		check(s(96 + 488, 88 + 10) = 1 AND s(96 + 122, 240 + 10) = 1 AND s(96 + 145, 88 + 5) /= 1,
			"comparison grid wrong");
		ASSERT errs = 0 REPORT "scope: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "scope: PASS, three frames: columns, ring order, bars, records, flags, lines, comparison";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
