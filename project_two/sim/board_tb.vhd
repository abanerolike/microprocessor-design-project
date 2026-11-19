LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;
USE work.gfm_pkg.ALL;

-- Smoke test of the DE2 top. The core, scen and disp have their own testbenches; this one checks what
-- only the top does.
--   the start state in gfm_pkg equals line 0 of the pre-trip window (grid side 0, all UFLS stages armed)
--   power-up runs sat, 1.2 pu, trip B, manual trip: LEDR7 and LEDR11 only, no LEDG (model blinking is
--   not checked, 0.13 s period)
--   HEX shows 6000 and ---- before the trip; SW17 switches the page (LEDG5 after its two flip-flops,
--   HEX at the next refresh, 200 clocks here)
--   a reset with SW4..0 = 01011 shows fb, the 1.2 then 1.0 pu mode and trip A; switches moved after the
--   reset change nothing; KEY1 trips within a step (LEDG1), then HEX3..0 shows the lowest frequency, and
--   page 1 shows shed 0000 and time 0000
--   limit mode 11 lights LEDG8 and holds the model: KEY1 does nothing
--   the LCD is powered and write only, and stays idle in its 100 ms power-up wait (1 clock per us here)
--   VGA: sync on green off and line syncs running (timing and drawing: vga_tb, scope_tb, screen_tb)
--   the LCD text follows the page and the settings read at reset: power-up, SW17 both ways, the 01011
--   and 10101 resets (switches already moved) and mode 11, each within 3 ms (bus timing: lcd_tb)
ENTITY board_tb IS
	GENERIC (fname : STRING := "vectors/held_fb_pretrip.txt");
END board_tb;

ARCHITECTURE a OF board_tb IS
	SIGNAL clk : STD_LOGIC := '0';
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL key : STD_LOGIC_VECTOR(1 DOWNTO 0) := "11";
	SIGNAL sw : STD_LOGIC_VECTOR(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL h : segs;
	SIGNAL ledr : STD_LOGIC_VECTOR(17 DOWNTO 0);
	SIGNAL ledg : STD_LOGIC_VECTOR(8 DOWNTO 0);
	SIGNAL ld : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL lrw, len, lrs, lon, lbl : STD_LOGIC;
	SIGNAL vr, vg, vbl : STD_LOGIC_VECTOR(9 DOWNTO 0);
	SIGNAL vck, vhs, vvs, vbk, vsy : STD_LOGIC;
	SIGNAL passes : INTEGER := 0;
	SIGNAL shown : STRING(1 TO 32);
BEGIN
	dut : ENTITY work.board GENERIC MAP (200, 1) PORT MAP (clk, key, sw, h(0), h(1), h(2), h(3), h(4), h(5), h(6), h(7), ledr, ledg, ld,
		lrw, len, lrs, lon, lbl, vr, vg, vbl, vck, vhs, vvs, vbk, vsy);

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

	-- LCD text read on the falling edge of e; a pass ends at the next line 1 address
	PROCESS
		VARIABLE adr : INTEGER := 1;
		VARIABLE scr : STRING(1 TO 32);
	BEGIN
		WAIT UNTIL len = '0' AND len'EVENT;
		IF lrs = '0' AND ld = x"80" THEN
			IF adr = 33 THEN
				shown <= scr;
				passes <= passes + 1;
			END IF;
			adr := 1;
		ELSIF lrs = '0' AND ld = x"C0" THEN
			adr := 17;
		ELSIF lrs = '1' AND adr <= 32 THEN
			scr(adr) := CHARACTER'VAL(TO_INTEGER(UNSIGNED(ld)));
			adr := adr + 1;
		END IF;
	END PROCESS;

	PROCESS
		FILE fv : TEXT OPEN READ_MODE IS fname;
		VARIABLE l : LINE;
		VARIABLE k, errs : INTEGER := 0;
		VARIABLE r : row18;
		VARIABLE w40 : STD_LOGIC_VECTOR(39 DOWNTO 0);
		VARIABLE w32 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w28 : STD_LOGIC_VECTOR(27 DOWNTO 0);
		VARIABLE w16 : STD_LOGIC_VECTOR(15 DOWNTO 0);
		VARIABLE w4  : STD_LOGIC_VECTOR(3 DOWNTO 0);

		PROCEDURE check (ok : BOOLEAN; s : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT s SEVERITY ERROR;
			END IF;
		END check;

		PROCEDURE wait_clocks (n : INTEGER) IS
		BEGIN
			FOR i IN 1 TO n LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
			WAIT FOR 1 ns;
		END wait_clocks;

		FUNCTION pat (c : CHARACTER) RETURN STD_LOGIC_VECTOR IS
		BEGIN
			CASE c IS
				WHEN '0' => RETURN "1000000";
				WHEN '6' => RETURN "0000010";
				WHEN OTHERS => RETURN "0111111";
			END CASE;
		END pat;

		PROCEDURE show (s : STRING; m : STRING) IS   -- s = HEX7 .. HEX0
		BEGIN
			FOR i IN 0 TO 7 LOOP
				check(h(7 - i) = pat(s(s'LEFT + i)), "HEX" & INTEGER'IMAGE(7 - i) & " wrong: " & m);
			END LOOP;
		END show;

		PROCEDURE says (s : STRING) IS              -- the first pass that starts after this call
			VARIABLE p : INTEGER;
		BEGIN
			p := passes;
			WAIT UNTIL passes = p + 2 FOR 3 ms;
			check(passes = p + 2 AND shown = s, "LCD text " & shown & " not " & s);
		END says;

		PROCEDURE reset (s : STD_LOGIC_VECTOR(4 DOWNTO 0)) IS
		BEGIN
			sw(4 DOWNTO 0) <= s;
			key(0) <= '0';
			wait_clocks(5);
			key(0) <= '1';
			wait_clocks(5);
			sw(4 DOWNTO 0) <= NOT s;                 -- read at reset only
			wait_clocks(195);
		END reset;
	BEGIN
		readline(fv, l);
		rowread(l, k, r);
		FOR i IN 0 TO 17 LOOP
			check(ST_D(i) = r(i), "start word " & INTEGER'IMAGE(i) & " differs from line 0");
		END LOOP;
		hrd(l, w40);
		check(ST_TH = UNSIGNED(w40), "start phase differs from line 0");
		hrd(l, w40);
		check(UNSIGNED(w40) = 0, "grid phase of line 0 is not 0");
		FOR i IN 1 TO 4 LOOP                         -- x, pm, psum, shed
			IF i = 3 THEN
				hrd(l, w28);
				check(SIGNED(w28) = 0, "psum of line 0 is not 0");
			ELSE
				hrd(l, w32);
				check(SIGNED(w32) = 0, "grid word of line 0 is not 0");
			END IF;
		END LOOP;
		FOR j IN 0 TO 6 LOOP
			hrd(l, w16);
			check(UNSIGNED(w16) = 0, "UFLS tick count of line 0 is not 0");
		END LOOP;
		FOR j IN 0 TO 6 LOOP
			hrd(l, w4);
			check(w4 = "0001", "UFLS stage of line 0 not armed");
		END LOOP;

		wait_clocks(200);
		check(UNSIGNED(ledg(5 DOWNTO 0)) = 0 AND ledg(8 DOWNTO 7) = "00" AND TO_INTEGER(UNSIGNED(ledr)) = 2 ** 11 + 2 ** 7,
			"power-up LEDs wrong");
		check(lon = '1' AND lrw = '0' AND len = '0', "LCD not powered, not write only, or written before 100 ms");
		check(vsy = '0', "VGA sync on green not off");
		FOR i IN 1 TO 1700 LOOP                              -- a VGA line is 1600 clocks
			EXIT WHEN vhs = '0';
			wait_clocks(1);
		END LOOP;
		check(vhs = '0', "no VGA line sync");
		show("6000----", "before the trip");
		sw(17) <= '1';
		wait_clocks(1);
		check(ledg(5) = '0', "page LED follows SW17 without its two flip-flops");
		wait_clocks(2);
		check(ledg(5) = '1', "page LED does not follow SW17 within its two flip-flops");
		wait_clocks(300);
		show("0000----", "page 1 before the trip");
		says("B3.3GW SAT 1.2puSHD10MW TIME10ms");
		sw(17) <= '0';
		says("B3.3GW SAT 1.2puNOW10mHzMIN10mHz");

		reset("01011");
		check(ledg(4 DOWNTO 3) = "01" AND TO_INTEGER(UNSIGNED(ledr)) = 2 ** 10 + 2 ** 8,
			"fb, 1.2 then 1.0 pu and trip A LEDs wrong, or the switches were read after the reset");
		says("A1.4GW FB  SPEC NOW10mHzMIN10mHz");
		key(1) <= '0';
		wait_clocks(60);
		check(ledg(1) = '1' AND ledg(2) = '0', "no trip at the next step after KEY1, or 1.0 pu too early");
		key(1) <= '1';
		wait_clocks(300);
		show("60006000", "lowest frequency right after the trip");
		sw(17) <= '1';
		wait_clocks(300);
		show("00000000", "shed and time right after the trip");

		reset("10101");                             -- fb with trip B: catches fb and trip swapped
		says("B3.3GW FB  NOLIMSHD10MW TIME10ms");
		reset("00110");
		key(1) <= '0';
		wait_clocks(200);
		check(ledg(8) = '1' AND ledg(1) = '0', "mode 11 not flagged, or the model ran and tripped");
		says("SW2:1=11 INVALIDSHD10MW TIME10ms");     -- SW17 is still 1

		ASSERT errs = 0 REPORT "board: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "board: PASS, start state, LEDs, pages, manual trip, mode 11 and LCD text";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
