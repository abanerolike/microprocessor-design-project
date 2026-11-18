LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- LCD driver at 1 clock per microsecond. A model of the display reads every write on the falling edge of e.
--   bus: no e pulse in the first 100 ms; rs and d steady from 2 clocks before e rises until it falls; e high
--   for 12 clocks or more (240 ns at 50 MHz)
--   init: 38 38 38 38 08 01 06 0C as commands, at least 10 ms, 200 us and 4 ms after writes 1, 2 and 6,
--   100 us between all others
--   then only the two line addresses as commands, each followed by 16 characters
--   five settings give the expected two lines; a page change in the middle of a pass shows on the next one
--   the whole test ends within 10 ms (about 3.2 ms needed)
ENTITY lcd_tb IS
END lcd_tb;

ARCHITECTURE a OF lcd_tb IS
	SIGNAL clk, rs, e, pg, fb, ta : STD_LOGIC := '0';
	SIGNAL lm : INTEGER RANGE 0 TO 3 := 0;
	SIGNAL d : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL passes, nch, errs : INTEGER := 0;   -- finished passes, characters in this pass, bus errors
	SIGNAL shown : STRING(1 TO 32);              -- text of the last finished pass
BEGIN
	dut : ENTITY work.lcd GENERIC MAP (1) PORT MAP (clk, pg, fb, ta, lm, rs, e, d);

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
	BEGIN
		WAIT UNTIL done FOR 10 ms;
		ASSERT done REPORT "lcd: FAIL, timeout: no finished pass" SEVERITY FAILURE;
		WAIT;
	END PROCESS;

	-- the display: values at an edge are the ones held during the clock that the edge ends
	PROCESS
		CONSTANT INIT : STD_LOGIC_VECTOR(63 DOWNTO 0) := x"383838380801060C";
		TYPE gaps IS ARRAY (1 TO 8) OF INTEGER;
		CONSTANT GAP : gaps := (10000, 200, 100, 100, 100, 4000, 100, 100);
		VARIABLE t, tc, tr, nw, adr, cnt : INTEGER := 0;
		VARIABLE pe, prs : STD_LOGIC := '0';
		VARIABLE pd : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"00";
		VARIABLE ws, wd : STD_LOGIC_VECTOR(8 DOWNTO 0);
		VARIABLE scr : STRING(1 TO 32) := (OTHERS => ' ');
		VARIABLE ok, l2 : BOOLEAN := FALSE;
	BEGIN
		WAIT UNTIL clk = '1' AND clk'EVENT;
		t := t + 1;
		IF rs /= prs OR d /= pd THEN
			tc := t;
		END IF;
		ok := TRUE;
		IF e = '1' AND pe = '0' THEN
			IF nw > 0 AND nw <= 8 THEN
				ok := t - tr >= GAP(nw);
			ELSIF nw > 8 THEN
				ok := t - tr >= 100;
			END IF;
			ok := ok AND t - tc >= 2 AND t > 100000;
			tr := t;
			ws := rs & d;
		ELSIF e = '0' AND pe = '1' THEN
			wd := rs & d;
			ok := wd = ws AND t - tr >= 12;
			nw := nw + 1;
			IF nw <= 8 THEN
				ok := ok AND wd = '0' & INIT(71 - 8 * nw DOWNTO 64 - 8 * nw);
			ELSIF rs = '0' AND d = x"80" AND (nw = 9 OR cnt = 32) THEN
				IF nw > 9 THEN
					shown <= scr;
					passes <= passes + 1;
				END IF;
				cnt := 0;
				adr := 1;
				l2 := FALSE;
			ELSIF rs = '0' AND d = x"C0" AND cnt = 16 THEN
				adr := 17;
				l2 := TRUE;
			ELSIF rs = '1' AND nw > 9 AND (adr <= 16 OR (l2 AND adr <= 32)) THEN
				scr(adr) := CHARACTER'VAL(TO_INTEGER(UNSIGNED(d)));
				adr := adr + 1;
				cnt := cnt + 1;
			ELSE
				ok := FALSE;
			END IF;
			nch <= cnt;
		ELSIF e = '1' AND t - tc < 1 THEN
			ok := FALSE;                         -- rs or d moved while e is high
		END IF;
		IF NOT ok THEN
			errs <= errs + 1;
			REPORT "lcd bus wrong at write " & INTEGER'IMAGE(nw) SEVERITY ERROR;
		END IF;
		pe := e;
		prs := rs;
		pd := d;
	END PROCESS;

	PROCESS
		VARIABLE bad, p : INTEGER := 0;

		PROCEDURE show (vta, vfb : STD_LOGIC; vlm : INTEGER; vpg : STD_LOGIC; s : STRING) IS
		BEGIN
			ta <= vta;
			fb <= vfb;
			lm <= vlm;
			pg <= vpg;
			p := passes;
			WAIT UNTIL passes = p + 2;
			IF shown /= s THEN
				bad := bad + 1;
				REPORT "lcd shows " & shown & " not " & s SEVERITY ERROR;
			END IF;
		END show;
	BEGIN
		show('0', '0', 0, '0', "B3.3GW SAT 1.2puNOW10mHzMIN10mHz");
		show('1', '1', 1, '1', "A1.4GW FB  SPEC SHD10MW TIME10ms");
		show('0', '1', 2, '0', "B3.3GW FB  NOLIMNOW10mHzMIN10mHz");
		show('1', '0', 3, '0', "SW2:1=11 INVALIDNOW10mHzMIN10mHz");
		show('1', '0', 2, '1', "A1.4GW SAT NOLIMSHD10MW TIME10ms");
		-- page 0 again, then page 1 after five characters of a pass: that pass keeps page 0
		pg <= '0';
		p := passes;
		WAIT UNTIL passes = p + 1;
		WAIT UNTIL nch = 5;
		pg <= '1';
		WAIT UNTIL passes'EVENT;
		IF shown(17 TO 32) /= "NOW10mHzMIN10mHz" THEN
			bad := bad + 1;
			REPORT "page changed inside a pass" SEVERITY ERROR;
		END IF;
		WAIT UNTIL passes'EVENT;
		IF shown(17 TO 32) /= "SHD10MW TIME10ms" THEN
			bad := bad + 1;
			REPORT "new page not shown on the next pass" SEVERITY ERROR;
		END IF;
		ASSERT bad = 0 AND errs = 0
			REPORT "lcd: FAIL, " & INTEGER'IMAGE(bad) & " text errors, " & INTEGER'IMAGE(errs) & " bus errors"
			SEVERITY FAILURE;
		REPORT "lcd: PASS, init, bus timing, five settings and the page latch";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
