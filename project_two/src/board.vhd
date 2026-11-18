LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- DE2 top: the emulator core with its board settings and display.
--   KEY0 reset, KEY1 manual trip; SW0 fb, SW2:1 limit mode, SW3 trip A, SW4 automatic trip (all five
--   read at reset); SW17 HEX page (live)
--   LEDR0..6 UFLS stage has shed; LEDR7..9 limit mode 1.2 pu / 1.2 then 1.0 pu / no limit; LEDR10..11
--   trip A / trip B
--   LEDG0 limiter acting now (current reference limit, not an overcurrent trip), LEDG1 after the trip,
--   LEDG2 the 1.0 pu limit is in force, LEDG3 fb, LEDG4 automatic trip, LEDG5 page 1, LEDG6 blinks while
--   the model runs, LEDG7 the limiter has acted since reset, LEDG8 reserved limit mode set
--   Setting LEDs show what was read at reset; LEDG5 shows the live page (after its two flip-flops).
ENTITY board IS
	GENERIC (nr : INTEGER := 5000000);              -- display refresh, clocks (0.1 s)
	PORT (CLOCK_50 : IN STD_LOGIC;
		KEY  : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
		SW   : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
		HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7 : OUT STD_LOGIC_VECTOR(6 DOWNTO 0);
		LEDR : OUT STD_LOGIC_VECTOR(17 DOWNTO 0);
		LEDG : OUT STD_LOGIC_VECTOR(8 DOWNTO 0));
END board;

ARCHITECTURE a OF board IS
	CONSTANT Z40 : UNSIGNED(39 DOWNTO 0) := (OTHERS => '0');
	CONSTANT Z32 : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	CONSTANT Z28 : SIGNED(27 DOWNTO 0) := (OTHERS => '0');
	CONSTANT TK0 : counts := (OTHERS => 0);
	CONSTANT AR0 : STD_LOGIC_VECTOR(0 TO 6) := "1111111";
	SIGNAL load, step, en, lim, pg, fb, ta, au, err, tr, sh, seen, blink : STD_LOGIC;
	SIGNAL lm : INTEGER RANGE 0 TO 3;
	SIGNAL t : INTEGER RANGE 0 TO 10000;
	SIGNAL dp, cap, p0, imx, x, xmin, shed : SIGNED(31 DOWNTO 0);
	SIGNAL pg0, ks : SIGNED(17 DOWNTO 0);
	SIGNAL t2 : SIGNED(37 DOWNTO 0);
	SIGNAL armed : STD_LOGIC_VECTOR(0 TO 6);
	SIGNAL hex : segs;
BEGIN
	sc : ENTITY work.scen PORT MAP (CLOCK_50, step, lim, KEY, SW(4 DOWNTO 0), SW(17), x, load, dp, cap, p0, imx, pg0,
		ks, t2, en, lm, pg, fb, ta, au, err, tr, sh, seen, blink, xmin, t);
	cr : ENTITY work.core PORT MAP (CLOCK_50, load, 0, dp, cap, pg0, ks, p0, imx, t2, en, ST_D, ST_TH, Z40, Z32, Z32,
		Z32, Z28, TK0, AR0, OPEN, step, OPEN, OPEN, OPEN, x, OPEN, shed, OPEN, OPEN, armed, OPEN, OPEN, OPEN, OPEN,
		OPEN, OPEN, OPEN, lim, OPEN, OPEN, OPEN, OPEN, OPEN);
	ds : ENTITY work.disp GENERIC MAP (nr) PORT MAP (CLOCK_50, step, pg, tr, x, xmin, shed, t, hex);

	HEX0 <= hex(0);
	HEX1 <= hex(1);
	HEX2 <= hex(2);
	HEX3 <= hex(3);
	HEX4 <= hex(4);
	HEX5 <= hex(5);
	HEX6 <= hex(6);
	HEX7 <= hex(7);
	g : FOR j IN 0 TO 6 GENERATE
		LEDR(j) <= NOT armed(j);
	END GENERATE;
	LEDR(7) <= '1' WHEN lm = 0 ELSE '0';
	LEDR(8) <= '1' WHEN lm = 1 ELSE '0';
	LEDR(9) <= '1' WHEN lm = 2 ELSE '0';
	LEDR(10) <= ta;
	LEDR(11) <= NOT ta;
	LEDR(17 DOWNTO 12) <= (OTHERS => '0');
	LEDG(0) <= lim;
	LEDG(1) <= tr;
	LEDG(2) <= sh;
	LEDG(3) <= fb;
	LEDG(4) <= au;
	LEDG(5) <= pg;
	LEDG(6) <= blink;
	LEDG(7) <= seen;
	LEDG(8) <= err;
END a;
