LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Controller block 1: measurement rotation, filters and power. The plant states i1, vc, i2 (dq frame of
-- the nominal speed) are turned into the inverter frame, rot = (c - j s) x, and pass a first-order filter;
-- the power p + jq = vcf conj(i2f) of the filtered values passes a slower one. All inputs are step-k
-- values, so the filter states seen by the other blocks stay at step k for the whole step.
-- f = i1f, vcf, i2f (re, im), pf, qf, Q(32,28). One shared 36 x 18 multiplier:
--   c 0..3   the four power products            c 4, 5  power filters
--   c 6..29  per quantity j (i1, vc, i2) a block of 8 clocks: four rotation products, two filters
-- sn must be valid from c = 7, cs from c = 6 (both come earlier from the NCO). The new states are held in
-- nf and written to f at the edge that ends c = 49.
ENTITY meas IS
	PORT (clk, load, step : IN STD_LOGIC;
		c      : IN INTEGER RANGE 0 TO 49;
		x      : IN words(0 TO 5);                   -- i1, vc, i2 (re, im)
		cs, sn : IN SIGNED(17 DOWNTO 0);             -- cos and sin of the inverter angle, Q16
		f0     : IN words(0 TO 7);
		f      : BUFFER words(0 TO 7) := (OTHERS => (OTHERS => '0')));
END meas;

ARCHITECTURE a OF meas IS
	SIGNAL p, q : SIGNED(53 DOWNTO 0);
	SIGNAL d    : SIGNED(35 DOWNTO 0);
	SIGNAL ro   : SIGNED(31 DOWNTO 0);
	SIGNAL nf   : words(0 TO 7);
BEGIN
	PROCESS (clk)
		VARIABLE j, ph : INTEGER RANGE 0 TO 7;
		VARIABLE ma : SIGNED(35 DOWNTO 0);
		VARIABLE mb : SIGNED(17 DOWNTO 0);
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			j := 0;
			ph := 0;
			IF c >= 6 AND c <= 29 THEN
				j := (c - 6) / 8;
				ph := (c - 6) MOD 8;
			END IF;
			-- multiplier inputs
			IF c <= 3 THEN                           -- vcf . i2f: rr, ii, ir, ri
				CASE c IS
					WHEN 0 =>
						ma := RESIZE(op(f(2)), 36);
						mb := op(f(4));
					WHEN 1 =>
						ma := RESIZE(op(f(3)), 36);
						mb := op(f(5));
					WHEN 2 =>
						ma := RESIZE(op(f(3)), 36);
						mb := op(f(4));
					WHEN OTHERS =>
						ma := RESIZE(op(f(2)), 36);
						mb := op(f(5));
				END CASE;
			ELSIF c <= 5 OR ph = 4 OR ph = 6 THEN    -- filters
				ma := d;
				mb := TO_SIGNED(AF1, 18);
				IF c <= 5 THEN
					mb := TO_SIGNED(AF2, 18);
				END IF;
			ELSE                                     -- rotation, ph 0..3: re cs, im sn, im cs, re sn
				ma := RESIZE(op(x(2 * j)), 36);
				IF ph = 1 OR ph = 2 THEN
					ma := RESIZE(op(x(2 * j + 1)), 36);
				END IF;
				mb := cs;
				IF ph = 1 OR ph = 3 THEN
					mb := sn;
				END IF;
			END IF;
			p <= ma * mb;

			-- each line uses the product formed one clock before
			IF c = 1 OR c = 3 OR (c >= 6 AND (ph = 1 OR ph = 3)) THEN
				q <= p;
			END IF;
			IF c = 2 THEN
				d <= RESIZE(sat(q + p, 32), 36) - f(6);
			ELSIF c = 4 THEN
				d <= RESIZE(sat(q - p, 32), 36) - f(7);
			ELSIF c = 5 THEN
				nf(6) <= sat(RESIZE(f(6), 36) + rs(p, FF2), 32);
			ELSIF c = 6 THEN
				nf(7) <= sat(RESIZE(f(7), 36) + rs(p, FF2), 32);
			ELSIF c >= 6 AND c <= 29 THEN
				CASE ph IS
					WHEN 2 => ro <= sat(rs(q + p, 2), 32);
					WHEN 3 => d <= RESIZE(ro, 36) - f(2 * j);
					WHEN 4 => ro <= sat(rs(q - p, 2), 32);
					WHEN 5 =>
						nf(2 * j) <= sat(RESIZE(f(2 * j), 36) + rs(p, FF1), 32);
						d <= RESIZE(ro, 36) - f(2 * j + 1);
					WHEN 7 => nf(2 * j + 1) <= sat(RESIZE(f(2 * j + 1), 36) + rs(p, FF1), 32);
					WHEN OTHERS => NULL;
				END CASE;
			END IF;

			IF load = '1' THEN
				f <= f0;
			ELSIF step = '1' THEN
				f <= nf;
			END IF;
		END IF;
	END PROCESS;
END a;
