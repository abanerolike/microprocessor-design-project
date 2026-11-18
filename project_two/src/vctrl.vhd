LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Controller block 2: droop, voltage PI and feed-forward, giving the current reference before the limit.
--   w - 1 = dp (p0 - pf)                      vref = 1 - dq qf
--   i_raw = kpv (vref - vcf) + uv + i2f + j bC w vcf
-- It also prepares, for block 4, the integrator steps of the voltage PI (Ts kiv (vref - vcf)) and the
-- cross term xL1 w i1f of the current PI. All inputs are step-k states, so nothing here is stored past
-- the step. One shared 36 x 18 multiplier; on each clock c it starts one product and the line below uses
-- the one started the clock before. Outputs are valid from: wm1 c = 2, uv1i 4, ir 10, xwi 13, xwr 14,
-- uv1r 15 (the 3e clock plan asks for 3, 5, 10 / 11, 13, 14, 15).
ENTITY vctrl IS
	PORT (clk : IN STD_LOGIC;
		c   : IN INTEGER RANGE 0 TO 49;
		p0  : IN SIGNED(31 DOWNTO 0);                -- power set point, Q28
		f   : IN words(0 TO 7);                      -- i1f, vcf, i2f (re, im), pf, qf
		uv  : IN words(0 TO 1);                      -- voltage PI integrator
		ir  : BUFFER words(0 TO 1) := (OTHERS => (OTHERS => '0'));   -- before the limit, Q(32,28)
		wm1 : BUFFER SIGNED(26 DOWNTO 0);            -- w - 1, Q28
		xwr, xwi   : OUT SIGNED(30 DOWNTO 0);
		uv1r, uv1i : OUT SIGNED(23 DOWNTO 0));
END vctrl;

ARCHITECTURE a OF vctrl IS
	CONSTANT ONE : SIGNED(35 DOWNTO 0) := SHIFT_LEFT(TO_SIGNED(1, 36), 28);
	SIGNAL p : SIGNED(53 DOWNTO 0);
	SIGNAL ev, ipi, wvr, wvi, ffr, ffi, wir, wii : SIGNED(35 DOWNTO 0);
	SIGNAL wop : SIGNED(17 DOWNTO 0);                -- w, Q(18,16)
BEGIN
	PROCESS (clk)
		VARIABLE ma : SIGNED(35 DOWNTO 0);
		VARIABLE mb : SIGNED(17 DOWNTO 0);
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			ma := (OTHERS => '0');
			mb := (OTHERS => '0');
			CASE c IS
				WHEN 0 =>
					ma := RESIZE(p0, 36) - f(6);
					mb := TO_SIGNED(KDP, 18);
				WHEN 1 =>
					ma := RESIZE(f(7), 36);
					mb := TO_SIGNED(KDQ, 18);
					wm1 <= RESIZE(rs(p, FDP), 27);
				WHEN 2 =>
					ma := -RESIZE(f(3), 36);
					mb := TO_SIGNED(KIV, 18);
					wop <= sat(rs(ONE + wm1, 12), 18);
					ev <= ONE - RESIZE(rs(p, FDQ), 36) - f(2);
				WHEN 3 =>
					ma := RESIZE(op(f(2)), 36);
					mb := wop;
					uv1i <= RESIZE(rs(p, FIV), 24);
				WHEN 4 =>
					ma := RESIZE(op(f(3)), 36);
					mb := wop;
					wvr <= RESIZE(rs(p, 2), 36);
				WHEN 5 =>
					ma := -RESIZE(f(3), 36);
					mb := TO_SIGNED(KPV, 18);
					wvi <= RESIZE(rs(p, 2), 36);
				WHEN 6 =>
					ma := wvr;
					mb := TO_SIGNED(BC, 18);
					ipi <= RESIZE(rs(p, FPV), 36);
				WHEN 7 =>
					ma := wvi;
					mb := TO_SIGNED(BC, 18);
					ffr <= RESIZE(rs(p, FBC), 36);
				WHEN 8 =>
					ma := ev;
					mb := TO_SIGNED(KPV, 18);
					ffi <= RESIZE(rs(p, FBC), 36);
				WHEN 9 =>
					ma := RESIZE(op(f(1)), 36);
					mb := wop;
					ir(0) <= sat(RESIZE(rs(p, FPV), 36) + uv(0) - ffi + f(4), 32);
					ir(1) <= sat(ipi + uv(1) + ffr + f(5), 32);
				WHEN 10 =>
					ma := RESIZE(op(f(0)), 36);
					mb := wop;
					wii <= RESIZE(rs(p, 2), 36);
				WHEN 11 =>
					ma := wii;
					mb := TO_SIGNED(XL1, 18);
					wir <= RESIZE(rs(p, 2), 36);
				WHEN 12 =>
					ma := wir;
					mb := TO_SIGNED(XL1, 18);
					xwi <= RESIZE(rs(p, FX1), 31);
				WHEN 13 =>
					ma := ev;
					mb := TO_SIGNED(KIV, 18);
					xwr <= RESIZE(rs(p, FX1), 31);
				WHEN 14 =>
					uv1r <= RESIZE(rs(p, FIV), 24);
				WHEN OTHERS => NULL;
			END CASE;
			p <= ma * mb;
		END IF;
	END PROCESS;
END a;
