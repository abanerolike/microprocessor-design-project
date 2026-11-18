LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Controller block 4: current PI, converter voltage, phase step and the two PI integrators.
--   dm = w - 1 - ks exc (ks = 0 turns fb off)      inc = KPH dm (phase count per microsecond)
--   v1c = vcf + kpi (il - i1f) + ui - j xL1 w i1f   in the inverter frame, then v1 = (c + j s) v1c
--   uv' = uv + Ts kiv (vref - vcf) + Ts kaw (il - ir)   (back-calculation anti-windup)
--   ui' = ui + Ts kii (il - i1f)
-- Units: one 36 x 18 (B) and two 18 x 18 (A) multipliers; on each clock c a product starts and the line
-- that uses it comes one clock later. Inputs must be valid from: wm1, uv1i 5, ir 11, exc 23, il 27 (both
-- parts), cs and sn 30, xwi 13, xwr 14, uv1r 15. Outputs are valid from: dm 28, inc 30, v1 33. The new
-- integrator states are held in ns and written to s at the edge that ends c = 49.
ENTITY cctrl IS
	PORT (clk, load, step : IN STD_LOGIC;
		c      : IN INTEGER RANGE 0 TO 49;
		ks     : IN SIGNED(17 DOWNTO 0);             -- fb gain at F 19
		cs, sn : IN SIGNED(17 DOWNTO 0);
		f      : IN words(0 TO 7);                   -- i1f, vcf, i2f (re, im), pf, qf
		ir, il : IN words(0 TO 1);
		exc    : IN SIGNED(32 DOWNTO 0);
		wm1    : IN SIGNED(26 DOWNTO 0);
		xwr, xwi   : IN SIGNED(30 DOWNTO 0);
		uv1r, uv1i : IN SIGNED(23 DOWNTO 0);
		s0     : IN words(0 TO 3);
		s      : BUFFER words(0 TO 3) := (OTHERS => (OTHERS => '0'));   -- uv, ui (re, im)
		v1r, v1i : OUT SIGNED(33 DOWNTO 0);
		dm     : BUFFER SIGNED(17 DOWNTO 0);         -- Q(18,20)
		inc    : OUT SIGNED(25 DOWNTO 0));
END cctrl;

ARCHITECTURE a OF cctrl IS
	SIGNAL pb : SIGNED(53 DOWNTO 0);
	SIGNAL p1, p2, q1, q2 : SIGNED(35 DOWNTO 0);
	SIGNAL der, dei, awr, awi : SIGNED(35 DOWNTO 0);
	SIGNAL vr, vi : SIGNED(17 DOWNTO 0);              -- v1c, Q(18,16)
	SIGNAL ns : words(0 TO 3);
BEGIN
	PROCESS (clk)
		VARIABLE ma : SIGNED(35 DOWNTO 0);
		VARIABLE mb, a1, b1, a2, b2 : SIGNED(17 DOWNTO 0);
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			ma := RESIZE(exc, 36);                   -- B: ks exc, kpi de, Ts kaw (il - ir), Ts kii de
			mb := (OTHERS => '0');
			a1 := dm;                                -- A1: KPH dm, then v1 products
			b1 := TO_SIGNED(KPH, 18);
			a2 := vr;
			b2 := sn;
			CASE c IS
				WHEN 26 => mb := ks;
				WHEN 27 =>
					dm <= sat(rs(RESIZE(wm1, 36) - rs(pb, FKS), 8), 18);
					der <= il(0) - RESIZE(f(0), 36);
					dei <= il(1) - RESIZE(f(1), 36);
					awr <= il(0) - RESIZE(ir(0), 36);
					awi <= il(1) - RESIZE(ir(1), 36);
				WHEN 28 =>
					ma := der;
					mb := TO_SIGNED(KPI, 18);
				WHEN 29 =>
					inc <= RESIZE(rs(p1, 20 + FKP), 26);
					vr <= sat(rs(RESIZE(f(2), 36) + rs(pb, FPI) + s(2) - xwi, 12), 18);
					ma := dei;
					mb := TO_SIGNED(KPI, 18);
				WHEN 30 =>
					vi <= sat(rs(RESIZE(f(3), 36) + rs(pb, FPI) + s(3) + xwr, 12), 18);
					a1 := vr;
					b1 := cs;
					ma := awr;
					mb := TO_SIGNED(KAW, 18);
				WHEN 31 =>
					ns(0) <= sat(RESIZE(s(0), 36) + uv1r + rs(pb, FAW), 32);
					q1 <= p1;
					q2 <= p2;
					a1 := vi;
					b1 := sn;
					a2 := vi;
					b2 := cs;
					ma := awi;
					mb := TO_SIGNED(KAW, 18);
				WHEN 32 =>
					v1r <= RESIZE(rs(RESIZE(q1, 37) - p1, 4), 34);
					v1i <= RESIZE(rs(RESIZE(q2, 37) + p2, 4), 34);
					ns(1) <= sat(RESIZE(s(1), 36) + uv1i + rs(pb, FAW), 32);
					ma := der;
					mb := TO_SIGNED(KII, 18);
				WHEN 33 =>
					ns(2) <= sat(RESIZE(s(2), 36) + rs(pb, FII), 32);
					ma := dei;
					mb := TO_SIGNED(KII, 18);
				WHEN 34 => ns(3) <= sat(RESIZE(s(3), 36) + rs(pb, FII), 32);
				WHEN OTHERS => NULL;
			END CASE;
			pb <= ma * mb;
			p1 <= a1 * b1;
			p2 <= a2 * b2;
			IF load = '1' THEN
				s <= s0;
			ELSIF step = '1' THEN
				s <= ns;
			END IF;
		END IF;
	END PROCESS;
END a;
