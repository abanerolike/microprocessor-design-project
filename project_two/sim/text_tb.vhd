LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- VGA text read back from whole frames: each character cell is cut from the captured screen, halved to
-- 8 x 8 (both pixels of every doubled pair must agree) and looked up in the font, so position, half row,
-- doubling, bit order and the three pipeline stages all have to be right.
--   fixed text: condition line, axis numbers, time axis, legend; the reference digit follows the trip
--   settings line and state for five settings (A/B, SAT/FB, 1.2pu, SPEC 1.2/1.0pu, NOLIM, INVALID)
--   values as dd.dd with Hz, GW, s; dashes for MIN and T before the trip; ERR when out of range
--   MIN OK / LOW at the edge: 59.2 Hz for trip B (lo = -28633115 OK, one less LOW) and 59.7 Hz for trip A
--   (-10737418 OK, one less LOW); OK green, LOW red
--   inputs changed just after vertical blank do not reach the frame being drawn
--   model field at the end of the condition line: AVG VDC -.- , PWM VDC2.4pu, PWM VDC4.0pu
ENTITY text_tb IS
END text_tb;

ARCHITECTURE a OF text_tb IS
	CONSTANT CHARS : STRING := " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ.:()-=%zpus";
	TYPE rows IS ARRAY (0 TO 383) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
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
	TYPE shot IS ARRAY (0 TO 639, 0 TO 479) OF INTEGER RANGE 0 TO 15;
	SIGNAL clk, ta, fb, sh, au, tr, dt, md, vd : STD_LOGIC := '0';
	SIGNAL lm : INTEGER RANGE 0 TO 3 := 0;
	SIGNAL dd : STD_LOGIC_VECTOR(79 DOWNTO 0) := (OTHERS => '0');
	SIGNAL db : STD_LOGIC_VECTOR(0 TO 4) := "00000";
	SIGNAL lo : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL r, g, b : STD_LOGIC_VECTOR(9 DOWNTO 0);
	SIGNAL ck, hs, vs, bl : STD_LOGIC;
	SIGNAL done : BOOLEAN := FALSE;
BEGIN
	dut : ENTITY work.screen GENERIC MAP (1) PORT MAP (clk, '1', '0', '0', '0', tr, sh, ta, fb, au, dt, lm, dd, db,
		lo, (OTHERS => '0'), (OTHERS => '0'), (OTHERS => '0'), (OTHERS => '0'), (OTHERS => '0'), r, g, b, ck, hs,
		vs, bl, md, vd);

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

	PROCESS
		VARIABLE s : shot;
		VARIABLE errs, px, ln : INTEGER := 0;
		VARIABLE pbl : STD_LOGIC := '0';

		PROCEDURE check (ok : BOOLEAN; m : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT m SEVERITY ERROR;
			END IF;
		END check;

		-- colour names: 0 black, 1 white, 2 green, 3 red, 4 light red, 5 other text colours, 6 graph grey
		FUNCTION name (rr, gg, bb : STD_LOGIC_VECTOR) RETURN INTEGER IS
			VARIABLE x, y, z : INTEGER;
		BEGIN
			x := TO_INTEGER(UNSIGNED(rr));
			y := TO_INTEGER(UNSIGNED(gg));
			z := TO_INTEGER(UNSIGNED(bb));
			IF x = 0 AND y = 0 AND z = 0 THEN RETURN 0;
			ELSIF x = 950 AND y = 950 AND z = 950 THEN RETURN 1;
			ELSIF x = 500 AND y = 1000 AND z = 300 THEN RETURN 2;
			ELSIF x = 1023 AND y = 120 AND z = 120 THEN RETURN 3;
			ELSIF x = 900 AND y = 350 AND z = 350 THEN RETURN 4;
			ELSIF x = y AND y = z THEN RETURN 6;
			END IF;
			RETURN 5;
		END name;

		PROCEDURE grab IS                                     -- the frame after the vs pulse now or next
		BEGIN
			IF vs = '1' THEN
				WAIT UNTIL vs = '0';
			END IF;
			WAIT UNTIL vs = '1';
			ln := -1;
			WHILE ln < 479 OR bl = '1' LOOP
				WAIT UNTIL ck = '1' AND ck'EVENT;
				IF bl = '1' AND pbl = '0' THEN
					ln := ln + 1;
					px := 0;
				END IF;
				IF bl = '1' THEN
					s(px, ln) := name(r, g, b);
					px := px + 1;
				END IF;
				pbl := bl;
			END LOOP;
		END grab;

		-- the n characters starting at half row h, column x; '?' for a cell that is no character
		FUNCTION read (v : shot; h, x, n : INTEGER) RETURN STRING IS
			VARIABLE t : STRING(1 TO n);
			VARIABLE w : STD_LOGIC_VECTOR(7 DOWNTO 0);
			VARIABLE good : BOOLEAN;
			VARIABLE x0, y0 : INTEGER;
		BEGIN
			FOR i IN 1 TO n LOOP
				t(i) := '?';
				x0 := (x + i - 1) * 16;
				y0 := h * 8;
				FOR k IN 0 TO 47 LOOP
					good := TRUE;
					FOR rr IN 0 TO 7 LOOP
						FOR cc IN 0 TO 7 LOOP
							FOR d IN 0 TO 3 LOOP
								IF (v(x0 + 2 * cc + d MOD 2, y0 + 2 * rr + d / 2) /= 0
									AND v(x0 + 2 * cc + d MOD 2, y0 + 2 * rr + d / 2) /= 6) /= (FONT(8 * k + rr)(7 - cc) = '1') THEN
									good := FALSE;
								END IF;
							END LOOP;
						END LOOP;
					END LOOP;
					IF good THEN
						t(i) := CHARS(k + 1);
					END IF;
				END LOOP;
			END LOOP;
			RETURN t;
		END read;

		PROCEDURE see (h, x : INTEGER; e : STRING) IS
			VARIABLE t : STRING(1 TO e'LENGTH);
		BEGIN
			t := read(s, h, x, e'LENGTH);
			check(t = e, "half row " & INTEGER'IMAGE(h) & " column " & INTEGER'IMAGE(x) & ": '" & t & "' not '" & e & "'");
		END see;

		IMPURE FUNCTION has (x, h, k : INTEGER) RETURN BOOLEAN IS  -- colour k in the character cell
		BEGIN
			FOR i IN 0 TO 15 LOOP
				FOR j IN 0 TO 15 LOOP
					IF s(16 * x + i, 8 * h + j) = k THEN
						RETURN TRUE;
					END IF;
				END LOOP;
			END LOOP;
			RETURN FALSE;
		END has;

		FUNCTION hex4 (n : INTEGER) RETURN STD_LOGIC_VECTOR IS  -- four BCD digits
		BEGIN
			RETURN STD_LOGIC_VECTOR(TO_UNSIGNED(n / 1000, 4) & TO_UNSIGNED(n / 100 MOD 10, 4)
				& TO_UNSIGNED(n / 10 MOD 10, 4) & TO_UNSIGNED(n MOD 10, 4));
		END hex4;
	BEGIN
		-- frame 1: trip B, SAT, 1.2 pu, automatic, before the trip
		au <= '1';
		dd <= hex4(1268) & hex4(0) & hex4(0) & hex4(5871) & hex4(6000);
		grab;
		grab;
		see(0, 0, "B3.3GW SAT 1.2pu            READY AUTO1s");
		see(2, 0, "H3.3s GFM10% P0 0.9pu R1GW  AVG VDC -.- ");
		see(4, 0, "F 60.00Hz           MIN --.--Hz      ");
		see(6, 0, "SHED 00.00GW        T --.--s");
		see(8, 0, "F(Hz)  F  REF59.2  UFLS LEVEL");
		see(11, 1, "61.0");
		see(14, 1, "60.0");
		see(19, 1, "59.0");
		see(23, 1, "58.0");
		see(28, 0, "I1(pu)  I1  IMAX    PK -.---pu");
		see(30, 2, "2.0");
		see(37, 2, "1.0");
		see(45, 2, "0.0");
		see(47, 1, "LIM");
		see(50, 0, "AGE(s)-20.97  -15    -10     -5    NOW");
		see(53, 0, "TRIP  STEP  UFLS");
		check(has(19, 8, 4), "UFLS LEVEL not light red");
		tr <= '1';                                       -- the trip shows at once, the HEX copy later
		grab;
		grab;
		see(0, 28, "TRIP AUTO   ");
		see(4, 20, "MIN --.--Hz");
		tr <= '0';

		-- frame 2: trip A, FB, SPEC after the switch, KEY1, after the trip; lowest exactly 59.7 Hz: OK
		ta <= '1';
		fb <= '1';
		lm <= 1;
		sh <= '1';
		au <= '0';
		tr <= '1';
		dt <= '1';
		md <= '1';                                       -- PWM model, vdc 2.4 pu
		dd <= hex4(1268) & hex4(2000) & hex4(960) & hex4(5871) & hex4(5992);
		lo <= TO_SIGNED(-10737418, 32);
		grab;
		grab;
		see(0, 0, "A1.4GW FB  SPEC 1.0pu       TRIP KEY1   ");
		see(4, 0, "F 59.92Hz           MIN 58.71Hz  OK  ");
		see(6, 0, "SHED 09.60GW        T 20.00s");
		see(8, 10, "REF59.7");
		check(has(33, 4, 2) AND has(34, 4, 2), "OK not green");
		see(28, 20, "PK 1.268pu");
		check(has(23, 28, 2) AND NOT has(23, 28, 1), "PK not green");
		see(2, 28, "PWM VDC2.4pu");

		-- frame 3: one LSB lower: LOW in red; out-of-range F; reserved mode
		lo <= TO_SIGNED(-10737419, 32);
		db <= "10001";
		lm <= 3;
		vd <= '1';
		grab;
		grab;
		see(0, 0, "SW2:1=11 INVALID            INVALID     ");
		see(2, 28, "PWM VDC4.0pu");
		see(4, 0, "F  ERR Hz           MIN 58.71Hz LOW  ");
		see(28, 20, "PK  ERR pu");
		check(has(32, 4, 3) AND has(34, 4, 3) AND NOT has(26, 4, 3), "LOW not red, or red elsewhere");

		-- frame 4, 5: trip B edge 59.2 Hz, NOLIM, SAT, 1.2 pu SPEC before the switch
		ta <= '0';
		fb <= '0';
		lm <= 2;
		db <= "00000";
		lo <= TO_SIGNED(-28633115, 32);
		grab;
		grab;
		see(0, 0, "B3.3GW SAT NOLIM            TRIP KEY1   ");
		see(4, 32, " OK");
		see(8, 10, "REF59.2");
		lo <= TO_SIGNED(-28633116, 32);
		lm <= 1;
		sh <= '0';
		grab;
		grab;
		see(4, 32, "LOW");
		see(0, 11, "SPEC 1.2pu");

		-- inputs changed right after vertical blank: the frame shows the old ones
		dd <= hex4(9999) & hex4(1111) & hex4(2222) & hex4(3333) & hex4(4444);
		grab;
		grab;
		WAIT UNTIL vs = '0';
		WAIT UNTIL vs = '1';                                  -- vb is behind, the frame not started
		dd <= hex4(1234) & hex4(5555) & hex4(6666) & hex4(7777) & hex4(8888);
		lo <= (OTHERS => '0');
		ln := -1;
		WHILE ln < 479 OR bl = '1' LOOP
			WAIT UNTIL ck = '1' AND ck'EVENT;
			IF bl = '1' AND pbl = '0' THEN
				ln := ln + 1;
				px := 0;
			END IF;
			IF bl = '1' THEN
				s(px, ln) := name(r, g, b);
				px := px + 1;
			END IF;
			pbl := bl;
		END LOOP;
		see(4, 0, "F 44.44Hz           MIN 33.33Hz LOW  ");
		see(28, 20, "PK 9.999pu");

		ASSERT errs = 0 REPORT "text: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "text: PASS, fixed text, five settings, values, MIN OK/LOW edges, PK, model, colours, frame copy";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
