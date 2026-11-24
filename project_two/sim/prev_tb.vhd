LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- The kept run, recorder and display together: its graph columns and its numbers must end at the same
-- column. Two steps per column, a step every 100 clocks, x = -n 2^16 (n = steps since the reset), so the
-- kept lowest x tells the step it was copied at. The test notes x after every edge that ends a column.
--   1 a run of 600 columns: the bank keeps columns 0..511 and the numbers are those of column 511
--   2 a save while a finished column waits for vb: that column is kept, in the bank and in the numbers
--   3 a save before the display copy of the last column is ready: the run ends one column before
ENTITY prev_tb IS
END prev_tb;

ARCHITECTURE a OF prev_tb IS
	TYPE xs IS ARRAY (0 TO 1023) OF SIGNED(31 DOWNTO 0);
	SIGNAL clk, load, step, vb, sv, rdy, ce, wr, dt : STD_LOGIC := '0';
	SIGNAL vbon, done : BOOLEAN := FALSE;
	SIGNAL n : INTEGER RANGE 0 TO 10000 := 0;
	SIGNAL ph : INTEGER RANGE 0 TO 99 := 0;
	SIGNAL x : SIGNED(31 DOWNTO 0);
	SIGNAL imx : SIGNED(31 DOWNTO 0) := TO_SIGNED(64 * 4194304, 32);    -- Imax row 63 in every column
	SIGNAL ra, wp : UNSIGNED(8 DOWNTO 0) := (OTHERS => '0');
	SIGNAL q, qp : STD_LOGIC_VECTOR(42 DOWNTO 0);
	SIGNAL nv, np : INTEGER RANGE 0 TO 512;
	SIGNAL hex : segs;
	SIGNAL dd : STD_LOGIC_VECTOR(79 DOWNTO 0);
	SIGNAL db : STD_LOGIC_VECTOR(0 TO 4);
	SIGNAL lo : SIGNED(31 DOWNTO 0);
	SIGNAL pv : shown;
	SIGNAL col : xs;
	SIGNAL nc : INTEGER := 0;                                 -- columns finished since the reset
BEGIN
	rc : ENTITY work.rec GENERIC MAP (2) PORT MAP (clk, load, step, vb, x, (OTHERS => '0'), (OTHERS => '0'),
		(OTHERS => '0'), imx, '0', '0', '1', '0', ra, q, wp, nv, sv, '1', rdy, ce, wr, qp, np);
	ds : ENTITY work.disp GENERIC MAP (1000) PORT MAP (clk, load, step, '0', '1', x, x, (OTHERS => '0'),
		(OTHERS => '0'), (OTHERS => '0'), n, hex, dd, db, dt, lo, '0', ce, wr, sv, X"00", rdy, pv);

	x <= -TO_SIGNED(n * 65536, 32);
	step <= '1' WHEN ph = 99 AND load = '0' ELSE '0';
	vb <= '1' WHEN vbon AND ph MOD 50 < 5 ELSE '0';

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

	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			ph <= (ph + 1) MOD 100;
			IF load = '1' THEN
				n <= 0;
				nc <= 0;
			ELSIF step = '1' THEN
				n <= n + 1;
				IF ce = '1' THEN                             -- this edge ends column nc
					col(nc) <= -TO_SIGNED((n + 1) * 65536, 32);
					nc <= nc + 1;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	PROCESS
		VARIABLE errs, k : INTEGER := 0;

		PROCEDURE check (ok : BOOLEAN; s : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT s SEVERITY ERROR;
			END IF;
		END check;

		PROCEDURE clocks (m : INTEGER) IS
		BEGIN
			FOR i IN 1 TO m LOOP
				WAIT UNTIL clk = '1' AND clk'EVENT;
			END LOOP;
			WAIT FOR 1 ns;
		END clocks;

		PROCEDURE save IS
		BEGIN
			load <= '1';
			sv <= '1';
			clocks(1);
			sv <= '0';
			clocks(3);
			load <= '0';
			vbon <= TRUE;
			clocks(200);                                    -- the swap reaches the screen at vb
		END save;

		PROCEDURE kept (c : INTEGER; s : STRING) IS        -- the kept run ends with column c
		BEGIN
			check(np = c + 1, s & ": np = " & INTEGER'IMAGE(np) & ", expected " & INTEGER'IMAGE(c + 1));
			check(pv.ok = '1' AND pv.lo = col(c), s & ": numbers not those of column " & INTEGER'IMAGE(c));
			ra <= TO_UNSIGNED(c, 9);
			clocks(2);
			check(qp(37 DOWNTO 31) = "0111111", s & ": column " & INTEGER'IMAGE(c) & " missing in the bank");
		END kept;

		PROCEDURE upto (c : INTEGER) IS                     -- run until column c has just ended
		BEGIN
			WAIT UNTIL clk = '1' AND clk'EVENT AND nc = c + 1;
			WAIT FOR 1 ns;
		END upto;
	BEGIN
		load <= '1';
		clocks(3);
		load <= '0';
		vbon <= TRUE;

		upto(599);                                         -- case 1
		clocks(150);
		save;
		kept(511, "600 columns");

		upto(9);                                           -- case 2: column 10 waits for vb
		clocks(150);
		vbon <= FALSE;
		upto(10);
		clocks(90);                                        -- copy ready after 80 clocks; ce of column 11 at 100
		check(rdy = '1', "display copy of column 10 not ready");
		save;
		kept(10, "save with a waiting column");

		upto(5);                                           -- case 3: column 6 ends 30 clocks before the save
		clocks(150);
		vbon <= FALSE;
		upto(6);
		clocks(30);
		check(rdy = '0', "display copy already ready");
		save;
		kept(5, "save before the display copy");

		ASSERT errs = 0 REPORT "prev: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "prev: PASS, graph and numbers end at the same column: 600 columns, waiting column, copy not ready";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
