LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- 16x2 character LCD (HD44780): line 1 names the run, line 2 labels the two HEX groups.
--   line 1: trip A1.4GW / B3.3GW, SAT / FB, limit 1.2pu / SPEC / NOLIM, or SW2:1=11 INVALID
--   line 2: page 0 NOW10mHzMIN10mHz, page 1 SHD10MW TIME10ms (the first 8 characters sit over HEX7..4)
-- Write only (RW = 0), so every command gets a fixed wait instead of a busy flag read. The datasheet times
-- are for a 270 kHz oscillator and grow on a slower one, so each wait is at least twice the datasheet one:
-- 100 ms after power-up, 10 ms and 200 us after the first two function sets, 4 ms after clear, 100 us else.
-- The init is the datasheet's init by instruction (three function sets), since the module gets its power
-- from LCD_ON and its internal reset is not relied on. After the init the 32 characters are written again
-- and again; the text of one pass is fixed when the pass starts, so a page change shows on the next pass.
ENTITY lcd IS
	GENERIC (us : INTEGER := 50);                  -- clocks per microsecond
	PORT (clk, pg, fb, ta : IN STD_LOGIC;
		lm  : IN INTEGER RANGE 0 TO 3;
		rs  : OUT STD_LOGIC;
		e   : OUT STD_LOGIC;
		d   : OUT STD_LOGIC_VECTOR(7 DOWNTO 0));
END lcd;

ARCHITECTURE a OF lcd IS
	TYPE bytes IS ARRAY (NATURAL RANGE <>) OF STD_LOGIC_VECTOR(7 DOWNTO 0);

	FUNCTION b (s : STRING) RETURN bytes IS
		VARIABLE r : bytes(1 TO s'LENGTH);
	BEGIN
		FOR i IN r'RANGE LOOP
			r(i) := STD_LOGIC_VECTOR(TO_UNSIGNED(CHARACTER'POS(s(s'LOW + i - 1)), 8));
		END LOOP;
		RETURN r;
	END b;

	-- function set 8 bit 2 lines (x4), display off, clear, entry mode increment, display on
	CONSTANT INIT : bytes(0 TO 7) := (x"38", x"38", x"38", x"38", x"08", x"01", x"06", x"0C");
	SIGNAL rdy, en : STD_LOGIC := '0';
	SIGNAL j : INTEGER RANGE 0 TO 41 := 0;         -- 0..7 init, 8 line 1 address, 9..24, 25 line 2, 26..41
	SIGNAL n : INTEGER RANGE 0 TO 100000 * us := 0;
	SIGNAL txt : bytes(0 TO 31);
BEGIN
	e <= en;
	rs <= '1' WHEN (j >= 9 AND j <= 24) OR j >= 26 ELSE '0';
	d <= INIT(j) WHEN j <= 7 ELSE x"80" WHEN j = 8 ELSE x"C0" WHEN j = 25 ELSE txt(j - 9) WHEN j <= 24
		ELSE txt(j - 10);

	PROCESS (clk)
		VARIABLE w : INTEGER RANGE 0 TO 10000 * us;
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			w := 100 * us;
			IF j = 0 THEN
				w := 10000 * us;
			ELSIF j = 1 THEN
				w := 200 * us;
			ELSIF j = 5 THEN
				w := 4000 * us;
			END IF;
			IF rdy = '0' AND n = 100000 * us THEN
				rdy <= '1';
				n <= 0;
			ELSIF rdy = '1' AND n = w THEN     -- next write: rs and d change here, e rises 4 clocks later
				n <= 0;
				IF j = 41 OR j = 7 THEN
					j <= 8;
					IF lm = 3 THEN
						txt(0 TO 15) <= b("SW2:1=11 INVALID");
					ELSE
						IF ta = '1' THEN
							txt(0 TO 6) <= b("A1.4GW ");
						ELSE
							txt(0 TO 6) <= b("B3.3GW ");
						END IF;
						IF fb = '1' THEN
							txt(7 TO 10) <= b("FB  ");
						ELSE
							txt(7 TO 10) <= b("SAT ");
						END IF;
						IF lm = 0 THEN
							txt(11 TO 15) <= b("1.2pu");
						ELSIF lm = 1 THEN
							txt(11 TO 15) <= b("SPEC ");
						ELSE
							txt(11 TO 15) <= b("NOLIM");
						END IF;
					END IF;
					IF pg = '1' THEN
						txt(16 TO 31) <= b("SHD10MW TIME10ms");
					ELSE
						txt(16 TO 31) <= b("NOW10mHzMIN10mHz");
					END IF;
				ELSE
					j <= j + 1;
				END IF;
			ELSE
				n <= n + 1;
			END IF;
			IF rdy = '1' AND n = 3 THEN             -- e high for clocks 4..28 of a write: 500 ns
				en <= '1';
			ELSIF n = 28 THEN
				en <= '0';
			END IF;
		END IF;
	END PROCESS;
END a;
