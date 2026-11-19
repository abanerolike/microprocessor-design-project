LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

-- VGA timing over two frames, read the way the DAC and the monitor see it: on the rising edge of ck.
--   ck: 20 ns high, 20 ns low; hs, vs and bl change only on the clock edge where ck falls
--   a line is 800 pixels: bl high for 640, hs low for 96 starting 16 pixels after bl falls, and bl rises
--   again 48 pixels after hs rises; a frame is 525 lines: 480 with bl, vs low for 2 lines starting 10
--   lines after the last shown line
--   vb: one clock per frame, 840,000 clocks apart, after the 480 shown lines
ENTITY vga_tb IS
END vga_tb;

ARCHITECTURE a OF vga_tb IS
	SIGNAL clk : STD_LOGIC := '0';
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL pe, vb, ck, hs, vs, bl : STD_LOGIC;
	SIGNAL hc : INTEGER RANGE 0 TO 799;
	SIGNAL vc : INTEGER RANGE 0 TO 524;
BEGIN
	dut : ENTITY work.vga PORT MAP (clk, pe, hc, vc, vb, ck, hs, vs, bl);

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
		VARIABLE errs, t, tv, nvb, px, shown, sv, vlow, fr : INTEGER := 0;
		VARIABLE pck, pbl, cb : STD_LOGIC := '0';
		VARIABLE phs, pvs, ch, cv : STD_LOGIC := '1';             -- syncs idle high
		VARIABLE seen, hf, bf : INTEGER := -1;          -- pixel of hs fall and of bl fall in the line

		PROCEDURE check (ok : BOOLEAN; s : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT s SEVERITY ERROR;
			END IF;
		END check;
	BEGIN
		WHILE fr < 3 LOOP
			WAIT UNTIL clk = '1' AND clk'EVENT;
			WAIT FOR 1 ns;
			t := t + 1;
			IF t > 4 THEN
				check(ck /= pck, "ck does not toggle every clock");
				check((hs = ch AND vs = cv AND bl = cb) OR (ck = '0' AND pck = '1'),
					"hs, vs or bl change while ck rises");
			END IF;
			IF vb = '1' THEN
				nvb := nvb + 1;
				check(nvb = 1 OR t - tv = 840000, "vb not 840,000 clocks after the last one");
				check(nvb = 1 OR shown = 480, "vb not after 480 shown lines");
				check(nvb = 1 OR sv = 480, "vb before the last shown line of the frame");
				tv := t;
				shown := 0;
			END IF;
			IF ck = '1' AND pck = '0' THEN               -- the DAC samples here
				px := px + 1;
				IF bl = '0' AND pbl = '1' THEN
					check(seen < 0 OR px - seen = 640, "bl high for " & INTEGER'IMAGE(px - seen) & " pixels");
					bf := px;
				END IF;
				IF hs = '0' AND phs = '1' THEN
					check(bf < 0 OR px - bf = 16, "hs does not fall 16 pixels after bl");
					hf := px;
				END IF;
				IF hs = '1' AND phs = '0' THEN
					check(px - hf = 96, "hs low for " & INTEGER'IMAGE(px - hf) & " pixels");
					bf := -1;
				END IF;
				IF bl = '1' AND pbl = '0' THEN           -- a shown line starts
					check(hf < 0 OR px - hf = 144 OR fr = 0, "bl does not rise 48 pixels after hs");
					check(seen < 0 OR px - seen = 800, "line is not 800 pixels");
					seen := px;
					shown := shown + 1;
					sv := sv + 1;
				END IF;
				IF vs = '0' AND pvs = '1' THEN
					vlow := px;
					check(fr = 0 OR sv = 480, "not 480 shown lines between two vs pulses");
					check(fr = 0 OR px - seen = 11 * 800, "vs does not start 10 lines after the last shown line");
					seen := -1;
				END IF;
				IF vs = '1' AND pvs = '0' THEN
					check(px - vlow = 1600, "vs low for " & INTEGER'IMAGE(px - vlow) & " pixels");
					fr := fr + 1;
					sv := 0;
				END IF;
				phs := hs;
				pvs := vs;
				pbl := bl;
			END IF;
			pck := ck;
			ch := hs;
			cv := vs;
			cb := bl;
		END LOOP;
		check(nvb >= 2, "fewer than two vb pulses");
		ASSERT errs = 0 REPORT "vga: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "vga: PASS, clock phase, line, frame, syncs and vb";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
