LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- Graph recorder with 4 steps per column. The test keeps its own copy of every column, built from the
-- same inputs with plain integer arithmetic (floor by hand, root by counting up), and reads the ring back.
--   inputs change every step and reach past both graph edges, |i1| above 2 pu, Imax on and off, and
--   every record bit
--   a column is written only on vb: a done column with no vb changes nothing
--   600 columns: nv stops at 512, the ring wraps, and the 512 newest columns match
--   a reset with a column waiting, then vb: nothing written; a reset on the same clock as vb: nothing
--   written; load held over steps (reserved mode): those steps are not in the next column
--   edge columns: |i1| exactly 2 pu and just below, x just inside and outside rows 0 and 127
ENTITY rec_tb IS
END rec_tb;

ARCHITECTURE a OF rec_tb IS
	CONSTANT NK : INTEGER := 4;
	TYPE cols IS ARRAY (0 TO 1023) OF STD_LOGIC_VECTOR(42 DOWNTO 0);
	SIGNAL clk, load, step, vb, lim, en, tr, sh : STD_LOGIC := '0';
	SIGNAL x, ir, ii, shed, imx : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL ra, wp : UNSIGNED(8 DOWNTO 0) := (OTHERS => '0');
	SIGNAL q : STD_LOGIC_VECTOR(42 DOWNTO 0);
	SIGNAL nv : INTEGER RANGE 0 TO 512;
	SIGNAL done : BOOLEAN := FALSE;
BEGIN
	dut : ENTITY work.rec GENERIC MAP (NK) PORT MAP (clk, load, step, vb, x, ir, ii, shed, imx, lim, en, tr, sh,
		ra, q, wp, nv);

	PROCESS
	BEGIN
		WHILE NOT done LOOP
			clk <= '0';
			WAIT FOR 10 ns;
			clk <= '1';
			WAIT FOR 10 ns;
		END LOOP;
		WAIT;
	END PROCESS;

	PROCESS
		VARIABLE errs, s, ncol : INTEGER := 0;
		VARIABLE exp : cols;
		VARIABLE seed : UNSIGNED(31 DOWNTO 0) := x"12345678";
		VARIABLE xl, xh : INTEGER;
		VARIABLE ml, mh : UNSIGNED(36 DOWNTO 0);
		VARIABLE ev : STD_LOGIC_VECTOR(3 DOWNTO 0);
		VARIABLE ptr, psh : STD_LOGIC := '0';
		VARIABLE psd : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
		VARIABLE ien : STD_LOGIC;
		VARIABLE iimx : INTEGER;

		PROCEDURE check (ok : BOOLEAN; m : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT m SEVERITY ERROR;
			END IF;
		END check;

		FUNCTION img (v : STD_LOGIC_VECTOR) RETURN STRING IS
			VARIABLE r : STRING(1 TO v'LENGTH);
		BEGIN
			FOR i IN v'RANGE LOOP
				r(v'LEFT - i + 1) := STD_LOGIC'IMAGE(v(i))(2);
			END LOOP;
			RETURN r;
		END img;

		PROCEDURE tick (n : INTEGER) IS
		BEGIN
			FOR i IN 1 TO n LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
			WAIT FOR 1 ns;
		END tick;

		FUNCTION rnd (v : UNSIGNED) RETURN UNSIGNED IS
		BEGIN
			RETURN RESIZE(v * TO_UNSIGNED(1664525, 32) + 1013904223, 32);
		END rnd;

		FUNCTION fl20 (v : INTEGER) RETURN INTEGER IS        -- floor(v / 2^20)
		BEGIN
			IF v >= 0 THEN
				RETURN v / 1048576;
			END IF;
			RETURN -((-v + 1048575) / 1048576);
		END fl20;

		FUNCTION frow (v : INTEGER) RETURN STD_LOGIC_VECTOR IS  -- below, above, row
			VARIABLE k : INTEGER;
		BEGIN
			k := 34 - fl20(v);
			IF k < 0 THEN
				RETURN "01" & "0000000";
			ELSIF k > 127 THEN
				RETURN "10" & "1111111";
			END IF;
			RETURN "00" & STD_LOGIC_VECTOR(TO_UNSIGNED(k, 7));
		END frow;

		FUNCTION irow (m : UNSIGNED) RETURN STD_LOGIC_VECTOR IS  -- above, row: root by counting up
			VARIABLE n, k : INTEGER;
		BEGIN
			n := TO_INTEGER(m(36 DOWNTO 16));
			k := 0;
			WHILE (k + 1) * (k + 1) <= n AND k < 128 LOOP
				k := k + 1;
			END LOOP;
			IF k >= 128 THEN
				RETURN "1" & "0000000";
			END IF;
			RETURN "0" & STD_LOGIC_VECTOR(TO_UNSIGNED(127 - k, 7));
		END irow;

		-- one model step: new random inputs, then the step pulse; the test's column follows along
		PROCEDURE one (keep : BOOLEAN; fx : INTEGER := 0; fa : INTEGER := -1) IS  -- fa >= 0: fixed x, i1
			VARIABLE xi, a, b : INTEGER;
			VARIABLE m : UNSIGNED(36 DOWNTO 0);
			VARIABLE fh, flo : STD_LOGIC_VECTOR(8 DOWNTO 0);
			VARIABLE ih, il : STD_LOGIC_VECTOR(7 DOWNTO 0);
		BEGIN
			seed := rnd(seed);
			xi := TO_INTEGER(SIGNED(seed(31 DOWNTO 4))) * 4;           -- about +-0.06 pu: past both edges
			IF seed(3 DOWNTO 0) = "0000" THEN
				xi := xi / 64;                                          -- often well inside the graph
			END IF;
			seed := rnd(seed);
			a := TO_INTEGER(SIGNED(seed(31 DOWNTO 14))) / 4;          -- Q14, +-2 pu
			seed := rnd(seed);
			b := TO_INTEGER(SIGNED(seed(31 DOWNTO 14))) / 4;
			IF seed(5 DOWNTO 0) = "000000" THEN
				a := a * 3;                                             -- now and then above 2 pu
			END IF;
			IF fa >= 0 THEN
				xi := fx;
				a := fa;
				b := 0;
			END IF;
			x <= TO_SIGNED(xi, 32);
			ir <= TO_SIGNED(a, 18) & SIGNED(seed(13 DOWNTO 0));       -- the low 14 bits must not matter
			ii <= TO_SIGNED(b, 18) & SIGNED(seed(19 DOWNTO 6));
			lim <= seed(20);
			tr <= seed(21) OR tr;                                       -- the trip rises once
			sh <= seed(22) AND seed(23);
			IF seed(24 DOWNTO 22) = "000" THEN
				shed <= shed + 4294967;
			END IF;
			en <= seed(25);
			imx <= TO_SIGNED(322122547, 32);
			IF seed(26) = '1' THEN
				imx <= TO_SIGNED(268435456, 32);
			END IF;
			WAIT FOR 1 ns;
			step <= '1';
			tick(1);
			step <= '0';
			IF keep THEN
				m := UNSIGNED(RESIZE(TO_SIGNED(a, 18) * TO_SIGNED(a, 18), 37) + RESIZE(TO_SIGNED(b, 18) * TO_SIGNED(b, 18), 37));
				IF s = 0 THEN
					xl := xi;
					xh := xi;
					ml := m;
					mh := m;
					ev := "0000";
				END IF;
				IF xi < xl THEN xl := xi; END IF;
				IF xi > xh THEN xh := xi; END IF;
				IF m < ml THEN ml := m; END IF;
				IF m > mh THEN mh := m; END IF;
				ev := ev OR ('0' & (sh AND NOT psh) & (tr AND NOT ptr) & lim);
				IF shed /= psd THEN
					ev(3) := '1';
				END IF;
				ien := en;
				iimx := TO_INTEGER(imx) / 4194304;
				s := s + 1;
				IF s = NK THEN
					fh := frow(xh);
					flo := frow(xl);
					ih := irow(mh);
					il := irow(ml);
					exp(ncol MOD 1024) := ev & ien & STD_LOGIC_VECTOR(TO_UNSIGNED(127 - iimx, 7)) & ih(7)
						& il(6 DOWNTO 0) & ih(6 DOWNTO 0) & flo(8) & fh(7) & flo(6 DOWNTO 0) & fh(6 DOWNTO 0);
					ncol := ncol + 1;
					s := 0;
				END IF;
			END IF;
			ptr := tr;
			psh := sh;
			psd := shed;
			tick(49);
		END one;

		PROCEDURE blank IS
		BEGIN
			vb <= '1';
			tick(1);
			vb <= '0';
		END blank;

		-- the ring as the screen reads it: the newest nv columns, oldest first
		PROCEDURE ring (m : STRING) IS
			VARIABLE bad : INTEGER := 0;
		BEGIN
			FOR c IN 512 - nv TO 511 LOOP
				ra <= wp + TO_UNSIGNED(c, 9);
				tick(2);
				IF q /= exp((ncol - 512 + c) MOD 1024) THEN
					IF bad = 0 THEN
						REPORT "column " & INTEGER'IMAGE(c) & " ring " & img(q) & " test " & img(exp((ncol - 512 + c) MOD 1024));
					END IF;
					bad := bad + 1;
				END IF;
			END LOOP;
			check(bad = 0, m & ": " & INTEGER'IMAGE(bad) & " columns differ");
		END ring;
	BEGIN
		load <= '1';
		tick(3);
		load <= '0';
		tick(2);
		FOR k IN 1 TO NK LOOP
			one(TRUE);
		END LOOP;
		tick(30);
		check(nv = 0, "a column went in without vb");
		blank;
		check(nv = 1 AND wp = 1, "first column not written on vb");
		ring("first column");
		FOR c IN 2 TO 600 LOOP                               -- vb after every column, somewhere in it
			FOR k IN 1 TO NK LOOP
				one(TRUE);
				IF k = 2 THEN
					blank;
				END IF;
			END LOOP;
		END LOOP;
		tick(30);
		blank;
		check(nv = 512 AND wp = 600 MOD 512, "nv " & INTEGER'IMAGE(nv) & " after 600 columns");
		ring("600 columns");

		FOR k IN 1 TO NK LOOP                                -- a column waits; reset; then vb
			one(FALSE);
		END LOOP;
		tick(30);
		load <= '1';
		tick(1);
		load <= '0';
		blank;
		check(nv = 0 AND wp = 0, "reset kept the waiting column or the count");
		FOR k IN 1 TO NK LOOP                                -- a column waits; reset on the same clock as vb
			one(FALSE);
		END LOOP;
		tick(30);
		load <= '1';
		vb <= '1';
		tick(1);
		load <= '0';
		vb <= '0';
		blank;
		check(nv = 0 AND wp = 0, "a column went in on the reset clock");

		load <= '1';                                         -- reserved mode: load held over steps
		FOR k IN 1 TO 3 LOOP
			one(FALSE);
		END LOOP;
		load <= '0';
		tick(2);
		ptr := '0';                                          -- the recorder forgot the last step too
		psh := '0';
		psd := (OTHERS => '0');
		ncol := 0;
		s := 0;
		FOR k IN 1 TO NK LOOP
			one(TRUE);
		END LOOP;
		tick(30);
		blank;
		check(nv = 1, "no column after load was released");
		ring("first column after load held");

		-- edges: |i1| = 2 pu exactly (above) and one LSB of the root below it; x on both sides of rows
		-- 0 and 127 (one column per value, all four steps the same)
		FOR e IN 0 TO 5 LOOP
			FOR k IN 1 TO NK LOOP
				CASE e IS
					WHEN 0 => one(TRUE, 0, 32768);                  -- (2^15)^2 / 2^16 = 16384: above
					WHEN 1 => one(TRUE, 0, 32767);                  -- 16383: row 0, not above
					WHEN 2 => one(TRUE, 35 * 1048576, 100);         -- row -1: above
					WHEN 3 => one(TRUE, 35 * 1048576 - 1, 100);     -- row 0
					WHEN 4 => one(TRUE, -93 * 1048576, 100);        -- row 127
					WHEN OTHERS => one(TRUE, -93 * 1048576 - 1, 100);   -- row 128: below
				END CASE;
			END LOOP;
			tick(30);
			blank;
		END LOOP;
		ring("edge columns");

		ASSERT errs = 0 REPORT "rec: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "rec: PASS, 608 columns, vb timing, ring wrap, resets, load held and row edges";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
