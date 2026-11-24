LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- VGA screen: timing, graph recorder, graph drawing and text. The graph inputs are the model values of
-- the step that ends (taken when step is high); load clears the graphs. The text takes the settings,
-- the trip state and the HEX display copy (dd, db, dt, lo) in vertical blank.
-- cmp = 1 shows the comparison view (taken in vertical blank, so recorder reads, graphs and text change
-- view on the same frame): this run and the kept previous one (pv, its columns in the
-- recorder) on a time axis from the reset. sv keeps the run at KEY0, rdy holds a column back until its
-- display copy is ready, ce and wr tell the display where columns end and when one is written.
ENTITY screen IS
	GENERIC (nk : INTEGER := 40960);                   -- model steps per column
	PORT (clk, load, step, lim, en, tr, sh, ta, fb, au, dt : IN STD_LOGIC;
		lm  : IN INTEGER RANGE 0 TO 3;
		dd  : IN STD_LOGIC_VECTOR(79 DOWNTO 0);
		db  : IN STD_LOGIC_VECTOR(0 TO 4);
		lo  : IN SIGNED(31 DOWNTO 0);
		x, ir, ii, shed, imx : IN SIGNED(31 DOWNTO 0);
		r, g, b : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);
		ck, hs, vs, bl : OUT STD_LOGIC;
		md, vd : IN STD_LOGIC := '0';                  -- for the text: PWM model, vdc 4.0 pu
		sv, cmp, ps, bz : IN STD_LOGIC := '0';
		rdy : IN STD_LOGIC := '1';
		sl  : IN INTEGER RANGE 0 TO 3 := 0;
		pv  : IN shown := NONE;
		ce, wr : OUT STD_LOGIC);
END screen;

ARCHITECTURE a OF screen IS
	SIGNAL pe, vb, ton : STD_LOGIC;
	SIGNAL hc : INTEGER RANGE 0 TO 799;
	SIGNAL vc : INTEGER RANGE 0 TO 524;
	SIGNAL wp, ra : UNSIGNED(8 DOWNTO 0);
	SIGNAL nv : INTEGER RANGE 0 TO 512;
	SIGNAL q, qp : STD_LOGIC_VECTOR(42 DOWNTO 0);
	SIGNAL np : INTEGER RANGE 0 TO 512;
	SIGNAL rgb, tc : STD_LOGIC_VECTOR(29 DOWNTO 0);
	SIGNAL cv : STD_LOGIC := '0';                        -- the view, changed only between frames
BEGIN
	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT AND vb = '1' THEN
			cv <= cmp;
		END IF;
	END PROCESS;
	tm : ENTITY work.vga PORT MAP (clk, pe, hc, vc, vb, ck, hs, vs, bl);
	rc : ENTITY work.rec GENERIC MAP (nk) PORT MAP (clk, load, step, vb, x, ir, ii, shed, imx, lim, en, tr, sh,
		ra, q, wp, nv, sv, cv, rdy, ce, wr, qp, np);
	sc : ENTITY work.scope PORT MAP (clk, pe, ta, ton, hc, vc, wp, nv, q, tc, ra, rgb, cv, qp, np);
	tx : ENTITY work.text PORT MAP (clk, pe, vb, ta, fb, sh, au, tr, dt, hc, vc, lm, dd, db, lo, ton, tc, md, vd,
		cmp, ps, bz, sl, pv);                         -- the text takes cmp in vertical blank itself
	r <= rgb(29 DOWNTO 20);
	g <= rgb(19 DOWNTO 10);
	b <= rgb(9 DOWNTO 0);
END a;
