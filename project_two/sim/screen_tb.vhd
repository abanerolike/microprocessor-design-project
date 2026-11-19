LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- Screen as a whole (timing, recorder, ring, drawing) with one model step per column, so each step is
-- one column and the frames show exactly which columns went in. Frames are captured on the rising edge
-- of ck while bl is high.
--   after a reset: no columns
--   a step right after vs waits for the next vertical blank: the frame being drawn does not show it,
--   the next one shows it as the rightmost column (row 10 for the frequency, row 63 for 1.0 pu)
--   a second step: rightmost column row 20, the column before it row 10 (the graph rolls left)
--   a step, then a reset before the vertical blank: the next frame has no columns
--   no steps at all for a frame: the syncs and the empty frame go on
ENTITY screen_tb IS
END screen_tb;

ARCHITECTURE a OF screen_tb IS
	TYPE shot IS ARRAY (0 TO 639, 0 TO 479) OF BOOLEAN;     -- frequency or current colour seen
	SIGNAL clk, load, step : STD_LOGIC := '0';
	SIGNAL x, ir : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL r, g, b : STD_LOGIC_VECTOR(9 DOWNTO 0);
	SIGNAL ck, hs, vs, bl : STD_LOGIC;
	SIGNAL done : BOOLEAN := FALSE;
BEGIN
	dut : ENTITY work.screen GENERIC MAP (1) PORT MAP (clk, load, step, '0', '1', '0', '0', '0', '0', '0', '0', 0,
		(OTHERS => '0'), "0000", (OTHERS => '0'), x, ir, (OTHERS => '0'), (OTHERS => '0'), TO_SIGNED(322122547, 32),
		r, g, b, ck, hs, vs, bl);

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

		PROCEDURE pulse (SIGNAL p : OUT STD_LOGIC) IS
		BEGIN
			WAIT UNTIL clk = '1' AND clk'EVENT;
			p <= '1';
			WAIT UNTIL clk = '1' AND clk'EVENT;
			p <= '0';
		END pulse;

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
				IF bl = '1' THEN                              -- cyan (frequency) or green (current)
					s(px, ln) := (r = "0100101100" AND g = "1110000100") OR (r = "0111110100" AND g = "1111101000");
					px := px + 1;
				END IF;
				pbl := bl;
			END LOOP;
		END grab;

		FUNCTION count (v : shot) RETURN INTEGER IS          -- columns with any data colour
			VARIABLE n : INTEGER := 0;
		BEGIN
			FOR k IN 96 TO 607 LOOP
				FOR y IN 88 TO 367 LOOP                     -- the two graphs, not the legend between them
					IF v(k, y) AND (y <= 215 OR y >= 240) THEN
						n := n + 1;
						EXIT;
					END IF;
				END LOOP;
			END LOOP;
			RETURN n;
		END count;
	BEGIN
		pulse(load);
		grab;
		check(count(s) = 0, "columns after a reset");

		WAIT UNTIL vs = '0';                                  -- step during the frame
		x <= TO_SIGNED(24 * 1048576, 32);                    -- 34 - 24 = row 10
		ir <= TO_SIGNED(268435456, 32);                      -- 1.0 pu: row 127 - 64 = 63
		pulse(step);
		grab;                                                -- drawn before the next blank: not yet
		check(count(s) = 0, "a column showed before the vertical blank");
		grab;
		check(count(s) = 1, INTEGER'IMAGE(count(s)) & " columns after one step");
		check(s(607, 88 + 10) AND NOT s(607, 88 + 9) AND NOT s(607, 88 + 11), "frequency not on row 10");
		check(s(607, 240 + 63) AND NOT s(607, 240 + 62), "current not on row 63");
		check(NOT s(606, 88 + 10), "a second column appeared");

		WAIT UNTIL vs = '0';
		x <= TO_SIGNED(14 * 1048576, 32);                    -- row 20
		pulse(step);
		grab;
		grab;
		check(count(s) = 2, INTEGER'IMAGE(count(s)) & " columns after two steps");
		check(s(607, 88 + 20) AND s(606, 88 + 10), "graph did not roll left");

		WAIT UNTIL vs = '0';                                  -- step, then reset before the blank
		pulse(step);
		FOR i IN 1 TO 100 LOOP
			WAIT UNTIL clk = '1' AND clk'EVENT;
		END LOOP;
		pulse(load);
		grab;
		grab;
		check(count(s) = 0, "the waiting column survived the reset");
		grab;                                                -- no steps: the frames go on, still empty
		check(count(s) = 0, "columns without steps");

		ASSERT errs = 0 REPORT "screen: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "screen: PASS, columns appear on the next blank, roll, reset with a waiting column";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
