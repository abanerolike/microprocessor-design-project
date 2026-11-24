LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- The whole emulator in one loop: step timer, inverter and grid angles, LCL plant, grid model and
-- controller. After load the loop runs on its own; only the scenario inputs come from outside and they
-- may change only at a step edge (the edge that ends c = 49).
--   scenario: dp lost generation (0 before the trip), cap reserve limit, pg0 pre-trip grid power,
--   p0 power set point, ks fb gain (0 = fb off), en, imx and t2 (en = 0 and imx = 1 pu for no limit,
--   t2 = ((imx - imx/2048)^2) >> 28, all three from the same Imax)
--   d holds the 18 device and controller words in the order of a vector line: i1, vc, i2, i1f, vcf, i2f
--   (re, im), uv, ui (re, im), pf, qf
-- md = 0: the LCL takes v1 straight from the controller (average model). md = 1: it takes the mean phase
-- voltage of the PWM (vdc by vs), so the same controller and plant run with switching. The PWM runs in
-- both modes; w* are its start values (defaults: the board start state with vdc 2.4 pu).
ENTITY core IS
	PORT (clk, load : IN STD_LOGIC;
		k0      : IN INTEGER RANGE 0 TO 1023;
		dp, cap : IN SIGNED(31 DOWNTO 0);
		pg0, ks : IN SIGNED(17 DOWNTO 0);
		p0, imx : IN SIGNED(31 DOWNTO 0);
		t2      : IN SIGNED(37 DOWNTO 0);
		en      : IN STD_LOGIC;
		d0      : IN words(0 TO 17);
		th0, thg0 : IN UNSIGNED(39 DOWNTO 0);
		x0, pm0, sh0 : IN SIGNED(31 DOWNTO 0);
		ps0     : IN SIGNED(27 DOWNTO 0);
		tk0     : IN counts;
		ar0     : IN STD_LOGIC_VECTOR(0 TO 6);
		c       : BUFFER INTEGER RANGE 0 TO 49;
		step    : BUFFER STD_LOGIC;
		d       : OUT words(0 TO 17);
		th, thg : BUFFER UNSIGNED(39 DOWNTO 0);
		x, pm, shed : BUFFER SIGNED(31 DOWNTO 0);
		psum    : BUFFER SIGNED(27 DOWNTO 0);
		ticks   : BUFFER counts;
		armed   : BUFFER STD_LOGIC_VECTOR(0 TO 6);
		cs, sn, cg, sg, pg, dm : BUFFER SIGNED(17 DOWNTO 0);
		il      : BUFFER words(0 TO 1);
		lim     : BUFFER STD_LOGIC;
		exc     : BUFFER SIGNED(32 DOWNTO 0);
		v1r, v1i : BUFFER SIGNED(33 DOWNTO 0);
		inc     : BUFFER SIGNED(25 DOWNTO 0);
		incg    : BUFFER SIGNED(24 DOWNTO 0);
		md, vs  : IN STD_LOGIC := '0';
		wq0     : IN INTEGER RANGE 0 TO 249 := 0;
		wth0    : IN UNSIGNED(39 DOWNTO 0) := ST_KN;
		wc0     : IN SIGNED(17 DOWNTO 0) := TO_SIGNED(65536, 18);
		ws0     : IN SIGNED(17 DOWNTO 0) := (OTHERS => '0');
		wda0, wdp0 : IN duties := ST_DU('0');
		wdc0    : IN deads := (100, 100, 100);
		wcm0    : IN STD_LOGIC_VECTOR(0 TO 2) := "111";
		wng0    : IN STD_LOGIC_VECTOR(0 TO 2) := ST_NG;
		wur0    : IN SIGNED(33 DOWNTO 0) := TO_SIGNED(ST_V1R, 34);
		wui0    : IN SIGNED(33 DOWNTO 0) := TO_SIGNED(ST_V1I, 34);
		go      : IN STD_LOGIC := '1';                    -- 0: hold the step at c = 45 (pause, slow motion)
		hl      : BUFFER STD_LOGIC);
END core;

ARCHITECTURE a OF core IS
	SIGNAL slow : STD_LOGIC;
	SIGNAL xp : words(0 TO 5);
	SIGNAL f0, f : words(0 TO 7);
	SIGNAL s : words(0 TO 3);
	SIGNAL ig : SIGNED(25 DOWNTO 0);
	SIGNAL n1r, n1i : SIGNED(31 DOWNTO 0);
	SIGNAL ur, ui, ar, ai : SIGNED(33 DOWNTO 0);
	SIGNAL run : STD_LOGIC;
BEGIN
	run <= NOT hl;
	f0 <= d0(6 TO 11) & d0(16 TO 17);
	d <= xp & f(0 TO 5) & s & f(6 TO 7);
	ig <= RESIZE(incg, 26);
	ar <= ur WHEN md = '1' ELSE v1r;
	ai <= ui WHEN md = '1' ELSE v1i;

	tm : ENTITY work.tick PORT MAP (clk, load, k0, c, step, slow, go, hl);
	n1 : ENTITY work.nco PORT MAP (clk, load, step, c, th0, inc, th, cs, sn);
	n2 : ENTITY work.nco PORT MAP (clk, load, step, c, thg0, ig, thg, cg, sg);
	pf : ENTITY work.plant_fast PORT MAP (clk, load, step, c, ar, ai, cg, sg,
		d0(0), d0(1), d0(2), d0(3), d0(4), d0(5), xp(0), xp(1), xp(2), xp(3), xp(4), xp(5), pg, n1r, n1i);
	pw : ENTITY work.pwm PORT MAP (clk, load, run, vs, c, v1r, v1i, n1r, n1i, wq0, wth0, wc0, ws0, wda0, wdp0, wdc0,
		wcm0, wng0, wur0, wui0, ur, ui, OPEN, OPEN, OPEN, OPEN, OPEN, OPEN, OPEN);
	ps : ENTITY work.plant_slow PORT MAP (clk, load, step, slow, c, pg, pg0, dp, cap, x0, pm0, sh0, ps0, tk0, ar0,
		x, pm, shed, psum, ticks, armed, incg);
	ct : ENTITY work.controller PORT MAP (clk, load, step, en, c, xp, cs, sn, p0, imx, t2, ks, f0, d0(12 TO 15),
		f, s, il, lim, exc, dm, v1r, v1i, inc);
END a;
