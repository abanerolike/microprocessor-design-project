LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Grid-forming controller: droop with a power filter, voltage PI, circular current limit with optional
-- saturation feedback (fb, gain ks; ks = 0 turns it off), current PI. Four blocks, each with its own multipliers:
--   meas (1 B)  rotation of i1, vc, i2 into the inverter frame, their filters, power filter
--   vctrl (1 B) droop and voltage PI -> current reference ir before the limit
--   limiter (1 A + 1 C) il, lim, exc
--   cctrl (1 B + 2 A) current PI -> converter voltage v1, phase step inc, PI integrators
-- Input x is the plant state of step k (held for the step); sn must be valid from c = 2 and cs from 3 (as
-- the NCO gives them). Outputs: inc valid from c = 30, v1 from 33. The twelve controller states (f in
-- meas, s in cctrl) are written at the edge that ends c = 49.
ENTITY controller IS
	PORT (clk, load, step, en : IN STD_LOGIC;
		c      : IN INTEGER RANGE 0 TO 49;
		x      : IN words(0 TO 5);                   -- plant i1, vc, i2 (re, im)
		cs, sn : IN SIGNED(17 DOWNTO 0);
		p0     : IN SIGNED(31 DOWNTO 0);
		imx    : IN SIGNED(31 DOWNTO 0);
		t2     : IN SIGNED(37 DOWNTO 0);
		ks     : IN SIGNED(17 DOWNTO 0);
		f0     : IN words(0 TO 7);
		s0     : IN words(0 TO 3);
		f      : BUFFER words(0 TO 7);               -- i1f, vcf, i2f (re, im), pf, qf
		s      : BUFFER words(0 TO 3);               -- uv, ui (re, im)
		il     : BUFFER words(0 TO 1);
		lim    : BUFFER STD_LOGIC;
		exc    : BUFFER SIGNED(32 DOWNTO 0);
		dm     : BUFFER SIGNED(17 DOWNTO 0);
		v1r, v1i : BUFFER SIGNED(33 DOWNTO 0);
		inc    : BUFFER SIGNED(25 DOWNTO 0));
END controller;

ARCHITECTURE a OF controller IS
	SIGNAL ir : words(0 TO 1);
	SIGNAL wm1 : SIGNED(26 DOWNTO 0);
	SIGNAL xwr, xwi : SIGNED(30 DOWNTO 0);
	SIGNAL uv1r, uv1i : SIGNED(23 DOWNTO 0);
BEGIN
	b1 : ENTITY work.meas PORT MAP (clk, load, step, c, x, cs, sn, f0, f);
	b2 : ENTITY work.vctrl PORT MAP (clk, c, p0, f, s(0 TO 1), ir, wm1, xwr, xwi, uv1r, uv1i);
	b3 : ENTITY work.limiter PORT MAP (clk, en, c, imx, t2, ir, il, lim, exc);
	b4 : ENTITY work.cctrl PORT MAP (clk, load, step, c, ks, cs, sn, f, ir, il, exc, wm1, xwr, xwi, uv1r, uv1i,
		s0, s, v1r, v1i, dm, inc);
END a;
