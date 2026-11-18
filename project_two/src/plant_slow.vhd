LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Grid frequency model, updated once every 1024 steps (1.024 ms): swing equation, governor with a
-- reserve cap, and the seven UFLS stages. x is the frequency deviation and pm the governor power, both
-- Q(32,31) per unit. Between updates it only adds the grid power sample pg into psum and gives the grid
-- angle step incg from the held x.
-- One shared multiplier; the clock c inside the step picks its inputs:
--   c 0: x -> incg    1: D x    2: (K/R) x    4: governor    8: r (mean pg - pg0)    10: swing
-- pg must be valid from c = 7. On the update step the UFLS stages run one per clock at c = 12..18 and
-- write ticks, armed and shed there; x, pm and psum are written at the edge that ends c = 49.
ENTITY plant_slow IS
	PORT (clk, load, step, slow : IN STD_LOGIC;
		c       : IN INTEGER RANGE 0 TO 49;
		pg, pg0 : IN SIGNED(17 DOWNTO 0);                -- grid power sample and its pre-trip mean, Q14
		dp, cap : IN SIGNED(31 DOWNTO 0);                -- lost generation (0 before the trip), reserve cap
		x0, pm0, sh0 : IN SIGNED(31 DOWNTO 0);
		ps0     : IN SIGNED(27 DOWNTO 0);
		tk0     : IN counts;
		ar0     : IN STD_LOGIC_VECTOR(0 TO 6);
		x, pm, shed : BUFFER SIGNED(31 DOWNTO 0) := (OTHERS => '0');
		psum    : BUFFER SIGNED(27 DOWNTO 0) := (OTHERS => '0');
		ticks   : BUFFER counts;
		armed   : BUFFER STD_LOGIC_VECTOR(0 TO 6);
		incg    : BUFFER SIGNED(24 DOWNTO 0));
END plant_slow;

ARCHITECTURE a OF plant_slow IS
	SIGNAL ps : SIGNED(27 DOWNTO 0);
	SIGNAL ma, dxk, dpm, dx : SIGNED(35 DOWNTO 0);
	SIGNAL mb : INTEGER RANGE 0 TO 131071;
	SIGNAL p  : SIGNED(53 DOWNTO 0);
	SIGNAL xn, pmn : SIGNED(31 DOWNTO 0);
BEGIN
	ps <= sat(RESIZE(psum, 29) + pg, 28);

	WITH c SELECT ma <=
		RESIZE(sat(rs(RESIZE(x, 33), 10), 18), 36) WHEN 0,
		RESIZE(x, 36) WHEN 1 | 2,
		dpm WHEN 4,
		dx WHEN OTHERS;
	WITH c SELECT mb <=
		KPH WHEN 0, DD WHEN 1, KR WHEN 2, GT WHEN 4, RR WHEN 8, GH WHEN OTHERS;

	PROCESS (clk)
		VARIABLE t : INTEGER RANGE 0 TO 16384;
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			p <= ma * TO_SIGNED(mb, 18);
			CASE c IS
				WHEN 1 => incg <= RESIZE(rs(p, 21 + FKP), 25);
				WHEN 2 => dxk <= RESIZE(rs(p, FDD), 36);
				WHEN 3 => dpm <= -RESIZE(rs(p, FKR), 36) - pm;
				WHEN 5 =>
					IF pm >= cap AND dpm > 0 THEN       -- held at the reserve cap while rising
						pmn <= pm;
					ELSE
						pmn <= sat(RESIZE(pm, 33) + rs(p, FGT), 32);
					END IF;
				WHEN 7 => dx <= RESIZE(rs(RESIZE(ps, 29), 10), 36) - pg0;   -- registered first: long add chain
				WHEN 9 => dx <= RESIZE(pm, 36) - dp - dxk + RESIZE(rs(p, FRR - 17), 36) + shed;
				WHEN 11 => xn <= sat(RESIZE(x, 33) + rs(p, FGH), 32);
				WHEN 12 TO 18 =>                         -- UFLS stage c - 12, with the new x
					IF slow = '1' AND armed(c - 12) = '1' THEN
						t := 0;
						IF xn < THR(c - 12) THEN
							t := ticks(c - 12) + 1;
						END IF;
						ticks(c - 12) <= t;
						IF t >= LIM(c - 12) THEN
							shed <= shed + AMT(c - 12);
							armed(c - 12) <= '0';
						END IF;
					END IF;
				WHEN OTHERS => NULL;
			END CASE;
			IF load = '1' THEN
				x <= x0;
				pm <= pm0;
				psum <= ps0;
				shed <= sh0;
				ticks <= tk0;
				armed <= ar0;
			ELSIF step = '1' AND slow = '1' THEN
				x <= xn;
				pm <= pmn;
				psum <= (OTHERS => '0');
			ELSIF step = '1' THEN
				psum <= ps;
			END IF;
		END IF;
	END PROCESS;
END a;
