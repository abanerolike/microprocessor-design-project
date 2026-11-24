LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- DE2 top: the emulator core with its board settings and display.
--   KEY0 reset, KEY1 manual trip; SW0 fb, SW2:1 limit mode, SW3 trip A, SW4 automatic trip, SW5 vdc
--   4.0 pu (else 2.4), SW6 PWM model (else average) (all seven read at reset); SW17 HEX page (live)
--   LEDR0..6 UFLS stage has shed; LEDR7..9 limit mode 1.2 pu / 1.2 then 1.0 pu / no limit; LEDR10..11
--   trip A / trip B
--   LEDG0 limiter acting now (current reference limit, not an overcurrent trip), LEDG1 after the trip,
--   LEDG2 the 1.0 pu limit is in force, LEDG3 fb, LEDG4 automatic trip, LEDG5 page 1, LEDG6 blinks while
--   the model runs, LEDG7 the limiter has acted since reset, LEDG8 reserved limit mode set
--   Setting LEDs show what was read at reset; LEDG5 shows the live page (after its two flip-flops).
--   The LCD names the run (line 1) and labels the HEX groups with their units (line 2, follows the page).
--   VGA: frequency and |i1| over the last 20.97 s, cleared by a reset, with the settings and the HEX
--   values as text, and the model in use (AVG, or PWM with its vdc).
--   SW10 (live) comparison view: the run and the previous one (kept at KEY0) over the first 20.97 s
--   from the reset, with a table of both. SW7 pause, KEY2 / KEY3 one graph column / 0.1 s while paused,
--   SW9:8 slow motion 1:1, 1:4, 1:10, 1:100 (all live). LEDR12 paused, LEDR13 step run, LEDR14 comparison.
ENTITY board IS
	GENERIC (nr : INTEGER := 5000000;               -- display refresh, clocks (0.1 s)
		us : INTEGER := 50;                         -- clocks per microsecond for the LCD waits
		nk : INTEGER := 40960);                     -- model steps per graph column
	PORT (CLOCK_50 : IN STD_LOGIC;
		KEY  : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
		SW   : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
		HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7 : OUT STD_LOGIC_VECTOR(6 DOWNTO 0);
		LEDR : OUT STD_LOGIC_VECTOR(17 DOWNTO 0);
		LEDG : OUT STD_LOGIC_VECTOR(8 DOWNTO 0);
		LCD_DATA : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		LCD_RW, LCD_EN, LCD_RS, LCD_ON, LCD_BLON : OUT STD_LOGIC;
		VGA_R, VGA_G, VGA_B : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
		VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK, VGA_SYNC : OUT STD_LOGIC);
END board;

ARCHITECTURE a OF board IS
	CONSTANT Z40 : UNSIGNED(39 DOWNTO 0) := (OTHERS => '0');
	CONSTANT Z32 : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	CONSTANT Z28 : SIGNED(27 DOWNTO 0) := (OTHERS => '0');
	CONSTANT TK0 : counts := (OTHERS => 0);
	CONSTANT AR0 : STD_LOGIC_VECTOR(0 TO 6) := "1111111";
	SIGNAL load, step, en, lim, pg, fb, ta, au, err, tr, sh, seen, blink, vs, md : STD_LOGIC;
	SIGNAL sv, go, hl, ps, bz, ce, wr, rdy, c1, cmp : STD_LOGIC;
	SIGNAL sl : INTEGER RANGE 0 TO 3;
	SIGNAL pv : shown;
	SIGNAL set : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL du : duties;
	SIGNAL lm : INTEGER RANGE 0 TO 3;
	SIGNAL t : INTEGER RANGE 0 TO 10000;
	SIGNAL dp, cap, p0, imx, x, xmin, shed : SIGNED(31 DOWNTO 0);
	SIGNAL pg0, ks : SIGNED(17 DOWNTO 0);
	SIGNAL t2 : SIGNED(37 DOWNTO 0);
	SIGNAL armed, la : STD_LOGIC_VECTOR(0 TO 6);
	SIGNAL ll : STD_LOGIC;
	SIGNAL hex : segs;
	SIGNAL d : words(0 TO 17);
	SIGNAL dd : STD_LOGIC_VECTOR(79 DOWNTO 0);
	SIGNAL db : STD_LOGIC_VECTOR(0 TO 4);
	SIGNAL dt : STD_LOGIC;
	SIGNAL lo : SIGNED(31 DOWNTO 0);
BEGIN
	sc : ENTITY work.scen PORT MAP (CLOCK_50, step, lim, KEY(1 DOWNTO 0), SW(6 DOWNTO 0), SW(17), x, load, dp, cap, p0,
		imx, pg0, ks, t2, en, lm, pg, fb, ta, au, err, tr, sh, seen, blink, xmin, t, vs, md, sv);
	rn : ENTITY work.run PORT MAP (CLOCK_50, load, step, ce, KEY(3 DOWNTO 2), SW(9 DOWNTO 7), go, ps, bz, sl);
	set <= fb & STD_LOGIC_VECTOR(TO_UNSIGNED(lm, 2)) & ta & au & md & vs & sh;
	PROCESS (CLOCK_50)                               -- the view switch passes two flip-flops
	BEGIN
		IF CLOCK_50 = '1' AND CLOCK_50'EVENT THEN
			c1 <= SW(10);
			cmp <= c1;
			IF load = '1' THEN                       -- the start state: lim has no reset, it waits for c = 13
				la <= AR0;
				ll <= '0';
			ELSIF step = '1' THEN                    -- LEDs of the last finished step (also while held)
				la <= armed;
				ll <= lim;
			END IF;
		END IF;
	END PROCESS;
	du <= ST_DU(vs);
	cr : ENTITY work.core PORT MAP (CLOCK_50, load, 0, dp, cap, pg0, ks, p0, imx, t2, en, ST_D, ST_TH, Z40, Z32, Z32,
		Z32, Z28, TK0, AR0, OPEN, step, d, OPEN, OPEN, x, OPEN, shed, OPEN, OPEN, armed, OPEN, OPEN, OPEN, OPEN,
		OPEN, OPEN, OPEN, lim, OPEN, OPEN, OPEN, OPEN, OPEN, md, vs, 0, ST_KN, TO_SIGNED(65536, 18), (OTHERS => '0'),
		du, du, (100, 100, 100), "111", ST_NG, TO_SIGNED(ST_V1R, 34), TO_SIGNED(ST_V1I, 34), go, hl);
	ds : ENTITY work.disp GENERIC MAP (nr) PORT MAP (CLOCK_50, load, step, pg, tr, x, xmin, shed, d(0), d(1), t, hex,
		dd, db, dt, lo, hl, ce, wr, sv, set, rdy, pv);
	lc : ENTITY work.lcd GENERIC MAP (us) PORT MAP (CLOCK_50, pg, fb, ta, lm, LCD_RS, LCD_EN, LCD_DATA);
	LCD_RW <= '0';
	LCD_ON <= '1';
	LCD_BLON <= '1';
	vg : ENTITY work.screen GENERIC MAP (nk) PORT MAP (CLOCK_50, load, step, lim, en, tr, sh, ta, fb, au, dt,
		lm, dd, db, lo, x, d(0), d(1), shed, imx, VGA_R, VGA_G, VGA_B, VGA_CLK, VGA_HS, VGA_VS, VGA_BLANK, md, vs,
		sv, cmp, ps, bz, rdy, sl, pv, ce, wr);
	VGA_SYNC <= '0';

	HEX0 <= hex(0);
	HEX1 <= hex(1);
	HEX2 <= hex(2);
	HEX3 <= hex(3);
	HEX4 <= hex(4);
	HEX5 <= hex(5);
	HEX6 <= hex(6);
	HEX7 <= hex(7);
	g : FOR j IN 0 TO 6 GENERATE
		LEDR(j) <= NOT la(j);
	END GENERATE;
	LEDR(7) <= '1' WHEN lm = 0 ELSE '0';
	LEDR(8) <= '1' WHEN lm = 1 ELSE '0';
	LEDR(9) <= '1' WHEN lm = 2 ELSE '0';
	LEDR(10) <= ta;
	LEDR(11) <= NOT ta;
	LEDR(12) <= ps;
	LEDR(13) <= bz;
	LEDR(14) <= cmp;
	LEDR(17 DOWNTO 15) <= (OTHERS => '0');
	LEDG(0) <= ll;
	LEDG(1) <= tr;
	LEDG(2) <= sh;
	LEDG(3) <= fb;
	LEDG(4) <= au;
	LEDG(5) <= pg;
	LEDG(6) <= blink;
	LEDG(7) <= seen;
	LEDG(8) <= err;
END a;
