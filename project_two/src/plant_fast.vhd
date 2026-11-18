LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Inverter LCL filter and grid tie, one semi-implicit Euler step per microsecond in the dq frame of the
-- nominal speed. i1 (inverter side), vc (capacitor) and i2 (grid side) are Q(32,28) per unit.
--   i1' = i1 + a1 (v1 - vc - r1 i1 - j xl1 i1)
--   vc' = vc + ac (i1' - i2 - j bc vc)          uses the new i1
--   i2' = i2 + a2 (vc' - vg - r2 i2 - j xl2 i2)  uses the new vc
-- The products of step-k states are formed first (c = 0..11), so only the chain that starts with v1 is
-- left for the end of the step. One shared 36 x 18 multiplier; the clock c picks its inputs:
--   0, 1 r1 i1   2, 5 xl1 i1   3, 4 vg . i2 (grid power)   6, 7 bc vc   8, 9 r2 i2   10, 11 xl2 i2
--   34, 35 a1   37, 38 ac   40, 41 a2
-- sg must be valid from c = 2, cg from c = 3, v1 from c = 33 (the controller writes it at the edge that
-- ends c = 32). pg is valid from c = 6. The new states are held in n1, nc, n2 (the last one written at the
-- edge that ends c = 42) and copied to i1, vc, i2 at the edge that ends c = 49.
ENTITY plant_fast IS
	PORT (clk, load, step : IN STD_LOGIC;
		c        : IN INTEGER RANGE 0 TO 49;
		v1r, v1i : IN SIGNED(33 DOWNTO 0);               -- converter voltage, Q28
		cg, sg   : IN SIGNED(17 DOWNTO 0);               -- grid voltage = cos and sin of the grid angle, Q16
		i1r0, i1i0, vcr0, vci0, i2r0, i2i0 : IN SIGNED(31 DOWNTO 0);
		i1r, i1i, vcr, vci, i2r, i2i : BUFFER SIGNED(31 DOWNTO 0) := (OTHERS => '0');
		pg       : OUT SIGNED(17 DOWNTO 0));             -- power into the grid source, Q14
END plant_fast;

ARCHITECTURE a OF plant_fast IS
	SIGNAL ma, s, e1r, e1i, b2r, b2i, e3r, e3i : SIGNED(35 DOWNTO 0);
	SIGNAL mb : SIGNED(17 DOWNTO 0);
	SIGNAL p, q : SIGNED(53 DOWNTO 0);
	SIGNAL n1r, n1i, ncr, nci, n2r, n2i : SIGNED(31 DOWNTO 0);

	FUNCTION r36 (v : SIGNED; n : NATURAL) RETURN SIGNED IS
	BEGIN
		RETURN RESIZE(rs(v, n), 36);
	END r36;

	-- Q(32,28) to an 18-bit Q14 operand
	FUNCTION op (v : SIGNED) RETURN SIGNED IS
	BEGIN
		RETURN RESIZE(sat(rs(RESIZE(v, 33), 14), 18), 36);
	END op;
BEGIN
	WITH c SELECT ma <=
		RESIZE(i1r, 36) WHEN 0 | 2, RESIZE(i1i, 36) WHEN 1 | 5, op(i2r) WHEN 3, op(i2i) WHEN 4,
		RESIZE(vcr, 36) WHEN 6, RESIZE(vci, 36) WHEN 7, RESIZE(i2r, 36) WHEN 8 | 10, RESIZE(i2i, 36) WHEN 9 | 11,
		s WHEN OTHERS;
	WITH c SELECT mb <=
		TO_SIGNED(R1, 18) WHEN 0 | 1, TO_SIGNED(XL1, 18) WHEN 2 | 5, cg WHEN 3, sg WHEN 4,
		TO_SIGNED(BC, 18) WHEN 6 | 7, TO_SIGNED(R2, 18) WHEN 8 | 9, TO_SIGNED(XL2, 18) WHEN 10 | 11,
		TO_SIGNED(A1, 18) WHEN 34 | 35, TO_SIGNED(AC, 18) WHEN 37 | 38, TO_SIGNED(A2, 18) WHEN OTHERS;

	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			p <= ma * mb;
			CASE c IS                                    -- each line uses the product formed one clock before
				WHEN 1 => e1r <= -RESIZE(vcr, 36) - r36(p, FR1);
				WHEN 2 => e1i <= -RESIZE(vci, 36) - r36(p, FR1);
				WHEN 3 => e1i <= e1i - r36(p, FX1);
				WHEN 4 => q <= p;
				WHEN 5 => pg <= sat(rs(q + p, 16), 18);
				WHEN 6 => e1r <= e1r + r36(p, FX1);
				WHEN 7 => b2i <= -RESIZE(i2i, 36) - r36(p, FBC);
				WHEN 8 => b2r <= -RESIZE(i2r, 36) + r36(p, FBC);
				WHEN 9 => e3r <= -SHIFT_LEFT(RESIZE(cg, 36), 12) - r36(p, FR2);
				WHEN 10 => e3i <= -SHIFT_LEFT(RESIZE(sg, 36), 12) - r36(p, FR2);
				WHEN 11 => e3i <= e3i - r36(p, FX2);
				WHEN 12 => e3r <= e3r + r36(p, FX2);
				WHEN 33 => s <= RESIZE(v1r, 36) + e1r;
				WHEN 34 => s <= RESIZE(v1i, 36) + e1i;
				WHEN 35 => n1r <= sat(RESIZE(i1r, 36) + r36(p, FA1), 32);
				WHEN 36 =>
					n1i <= sat(RESIZE(i1i, 36) + r36(p, FA1), 32);
					s <= RESIZE(n1r, 36) + b2r;
				WHEN 37 => s <= RESIZE(n1i, 36) + b2i;
				WHEN 38 => ncr <= sat(RESIZE(vcr, 36) + r36(p, FAC), 32);
				WHEN 39 =>
					nci <= sat(RESIZE(vci, 36) + r36(p, FAC), 32);
					s <= RESIZE(ncr, 36) + e3r;
				WHEN 40 => s <= RESIZE(nci, 36) + e3i;
				WHEN 41 => n2r <= sat(RESIZE(i2r, 36) + r36(p, FA2), 32);
				WHEN 42 => n2i <= sat(RESIZE(i2i, 36) + r36(p, FA2), 32);
				WHEN OTHERS => NULL;
			END CASE;
			IF load = '1' THEN
				i1r <= i1r0;
				i1i <= i1i0;
				vcr <= vcr0;
				vci <= vci0;
				i2r <= i2r0;
				i2i <= i2i0;
			ELSIF step = '1' THEN
				i1r <= n1r;
				i1i <= n1i;
				vcr <= ncr;
				vci <= nci;
				i2r <= n2r;
				i2i <= n2i;
			END IF;
		END IF;
	END PROCESS;
END a;
