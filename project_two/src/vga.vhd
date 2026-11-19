LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

-- 640 x 480 VGA timing from CLOCK_50 alone: a pixel every second clock (25 MHz, 59.52 Hz frame).
--   line 800 pixels: 640 shown, 16 front porch, 96 sync, 48 back porch; frame 525 lines: 480, 10, 2, 33;
--   both syncs active low
--   pe is high on every second clock; on those clocks the counters and all pixel registers move and
--   VGA_CLK (ck) falls, so the DAC samples RGB and blank on its rising edge 20 ns after they change.
--   hc, vc name the pixel that enters the pipeline; the drawing logic needs d pixel clocks, so the
--   sync and blank outputs are delayed by the same d.
--   vb is high for one clock as the frame leaves the last shown line: the time for frame updates.
ENTITY vga IS
	GENERIC (d : INTEGER := 3);
	PORT (clk : IN STD_LOGIC;
		pe  : BUFFER STD_LOGIC;
		hc  : BUFFER INTEGER RANGE 0 TO 799;
		vc  : BUFFER INTEGER RANGE 0 TO 524;
		vb, ck, hs, vs, bl : OUT STD_LOGIC);          -- bl = 0 outside the 640 x 480 area
END vga;

ARCHITECTURE a OF vga IS
	SIGNAL k : STD_LOGIC := '0';
	SIGNAL dh, dv : STD_LOGIC_VECTOR(1 TO d) := (OTHERS => '1');
	SIGNAL db : STD_LOGIC_VECTOR(1 TO d) := (OTHERS => '0');
BEGIN
	pe <= k;
	ck <= k;
	hs <= dh(d);
	vs <= dv(d);
	bl <= db(d);

	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			k <= NOT k;
			vb <= '0';
			IF k = '1' THEN
				IF hc = 799 THEN
					hc <= 0;
					IF vc = 524 THEN
						vc <= 0;
					ELSE
						vc <= vc + 1;
					END IF;
					IF vc = 479 THEN
						vb <= '1';
					END IF;
				ELSE
					hc <= hc + 1;
				END IF;
				dh <= '1' & dh(1 TO d - 1);
				dv <= '1' & dv(1 TO d - 1);
				db <= '0' & db(1 TO d - 1);
				IF hc >= 656 AND hc <= 751 THEN
					dh(1) <= '0';
				END IF;
				IF vc = 490 OR vc = 491 THEN
					dv(1) <= '0';
				END IF;
				IF hc < 640 AND vc < 480 THEN
					db(1) <= '1';
				END IF;
			END IF;
		END IF;
	END PROCESS;
END a;
