LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Controller block 3: circular limit of the current reference.
--   m2 = |ir|^2 from 18-bit operands; lim = m2 > t2, with t2 = (Imax - Imax/2048)^2 prepared outside
--   (it changes only with Imax) and lim held at 0 when en = 0
--   1/sqrt(m2): m2 = 4^e u with u in [1, 4) (e = -1..3), a seed from SEED_ROM, one Newton step
--     y = y0 (3 - u y0^2) / 2, so 1/sqrt(m2) = y / 2^e
--   |ir| = m2 y / 2^e, scale = Imax y / 2^e - 4 LSB (capped at 1 when e <= 0)
--   il = lim ? scale ir : ir,   exc = lim ? max(|ir| - Imax, 0) : 0
-- Everything runs every step on a fixed clock plan; lim only picks the outputs. m2 is held at 1/4 or more
-- so the seed address stays in range. Units: one 18 x 18 (A) and one 38 x 18 (C) multiplier.
-- ir must be valid from c = 11. lim is valid from c = 14, exc from 23, il re from 26 and im from 27.
ENTITY limiter IS
	PORT (clk, en : IN STD_LOGIC;
		c   : IN INTEGER RANGE 0 TO 49;
		imx : IN SIGNED(31 DOWNTO 0);                -- Imax, Q28 below 2 pu (1 pu when en = 0)
		t2  : IN SIGNED(37 DOWNTO 0);                -- limit threshold for m2, Q28
		ir  : IN words(0 TO 1);
		il  : BUFFER words(0 TO 1);
		lim : BUFFER STD_LOGIC;
		exc : BUFFER SIGNED(32 DOWNTO 0));
END limiter;

ARCHITECTURE a OF limiter IS
	SIGNAL pa : SIGNED(35 DOWNTO 0);
	SIGNAL pc : SIGNED(55 DOWNTO 0);
	SIGNAL mv : SIGNED(37 DOWNTO 0);
	SIGNAL e  : INTEGER RANGE -1 TO 3;
	SIGNAL u, z : SIGNED(20 DOWNTO 0);                -- u Q17 in [1, 4), z = 3 - u y0^2 (Q17)
	SIGNAL y0, y2, y1, scl : SIGNED(17 DOWNTO 0);     -- all below 2^17
BEGIN
	PROCESS (clk)
		VARIABLE sq : SIGNED(17 DOWNTO 0);
		VARIABLE ma : SIGNED(37 DOWNTO 0);
		VARIABLE mb : SIGNED(17 DOWNTO 0);
		VARIABLE m  : SIGNED(37 DOWNTO 0);
		VARIABLE n  : INTEGER RANGE -1 TO 3;
		VARIABLE v  : SIGNED(37 DOWNTO 0);
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			sq := op(ir(0));                         -- the 18 x 18 unit only squares: ir re, then y0
			IF c = 15 THEN
				sq := y0;
			END IF;
			pa <= sq * sq;
			ma := RESIZE(op(ir(1)), 38);
			mb := op(ir(1));
			CASE c IS
				WHEN 12 => mv <= RESIZE(pa, 38) + RESIZE(pc, 38);
				WHEN 13 =>
					lim <= '0';
					IF en = '1' AND mv > t2 THEN
						lim <= '1';
					END IF;
					m := mv;
					IF m < SHIFT_LEFT(TO_SIGNED(1, 38), 26) THEN
						m := SHIFT_LEFT(TO_SIGNED(1, 38), 26);
					END IF;
					n := -1;
					FOR i IN 0 TO 3 LOOP
						IF m >= SHIFT_LEFT(TO_SIGNED(1, 38), 28 + 2 * i) THEN
							n := i;
						END IF;
					END LOOP;
					mv <= m;
					e <= n;
					u <= RESIZE(SHIFT_RIGHT(m, 11 + 2 * n), 21);
				WHEN 14 => y0 <= TO_SIGNED(SEED_ROM(TO_INTEGER(u(20 DOWNTO 11)) - 64), 18);
				WHEN 16 => y2 <= RESIZE(rs(pa, 17), 18);
				WHEN 17 =>
					ma := RESIZE(u, 38);
					mb := y2;
				WHEN 18 => z <= TO_SIGNED(3 * 2 ** 17, 21) - RESIZE(rs(pc, 17), 21);
				WHEN 19 =>
					ma := RESIZE(z, 38);
					mb := y0;
				WHEN 20 => y1 <= RESIZE(SHIFT_RIGHT(pc, 18), 18);
				WHEN 21 =>
					ma := mv;
					mb := y1;
				WHEN 22 =>
					v := RESIZE(SHIFT_RIGHT(pc, 17 + e), 38) - imx;
					exc <= (OTHERS => '0');
					IF lim = '1' AND v > 0 THEN
						exc <= RESIZE(v, 33);
					END IF;
					ma := RESIZE(imx, 38);
					mb := y1;
				WHEN 23 =>
					v := RESIZE(SHIFT_RIGHT(pc, 29), 38) - 4;
					IF e <= 0 AND v > SHIFT_LEFT(TO_SIGNED(1, 38), 16 + e) THEN
						v := SHIFT_LEFT(TO_SIGNED(1, 38), 16 + e);
					END IF;
					scl <= RESIZE(v, 18);
				WHEN 24 =>
					ma := RESIZE(ir(0), 38);
					mb := scl;
				WHEN 25 =>
					il(0) <= ir(0);
					IF lim = '1' THEN
						il(0) <= RESIZE(rs(pc, 16 + e), 32);
					END IF;
					ma := RESIZE(ir(1), 38);
					mb := scl;
				WHEN 26 =>
					il(1) <= ir(1);
					IF lim = '1' THEN
						il(1) <= RESIZE(rs(pc, 16 + e), 32);
					END IF;
				WHEN OTHERS => NULL;
			END CASE;
			pc <= ma * mb;
		END IF;
	END PROCESS;
END a;
