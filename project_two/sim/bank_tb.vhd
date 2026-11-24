LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- The two run banks of rec, one step per column. A column is known by its frequency row (34 + column
-- number mod 90, from x) and its run by the Imax row (127 - run number).
--   1 a run of 600 columns, saved: the previous bank holds its first 512, np = 512
--   2 the comparison view reads the bank of the run going on, from address 0; the roll view the ring
--     (after 600 columns the ring holds columns 512..599 at addresses 0..87)
--   3 a second run of 100 columns, saved: the banks swap, np = 100, the new run writes the other bank
--   4 a save with no written column and a load without save keep the previous run
--   5 the banks swap on the screen only at vb
--   6 rdy = 0 holds the waiting column; it is written with the next vb after rdy returns
ENTITY bank_tb IS
END bank_tb;

ARCHITECTURE a OF bank_tb IS
	SIGNAL clk, load, step, vb, sv, cv, ce, wr : STD_LOGIC := '0';
	SIGNAL rdy : STD_LOGIC := '1';
	SIGNAL x, imx : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL ra, wp : UNSIGNED(8 DOWNTO 0) := (OTHERS => '0');
	SIGNAL q, qp : STD_LOGIC_VECTOR(42 DOWNTO 0);
	SIGNAL nv, np : INTEGER RANGE 0 TO 512;
	SIGNAL done : BOOLEAN := FALSE;
BEGIN
	dut : ENTITY work.rec GENERIC MAP (1) PORT MAP (clk, load, step, vb, x, (OTHERS => '0'), (OTHERS => '0'),
		(OTHERS => '0'), imx, '0', '0', '0', '0', ra, q, wp, nv, sv, cv, rdy, ce, wr, qp, np);

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
		VARIABLE errs : INTEGER := 0;

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

		PROCEDURE columns (r, c : INTEGER) IS               -- run r, c columns, each written at once
		BEGIN
			imx <= TO_SIGNED(r * 4194304, 32);
			FOR k IN 0 TO c - 1 LOOP
				x <= -TO_SIGNED(k MOD 90 * 1048576, 32);
				step <= '1';
				clocks(1);
				step <= '0';
				clocks(24);
			END LOOP;
		END columns;

		FUNCTION col (v : STD_LOGIC_VECTOR(42 DOWNTO 0); r, k : INTEGER) RETURN BOOLEAN IS
		BEGIN
			RETURN TO_INTEGER(UNSIGNED(v(6 DOWNTO 0))) = 34 + k MOD 90
				AND TO_INTEGER(UNSIGNED(v(37 DOWNTO 31))) = 127 - r;
		END col;

		PROCEDURE reads (r, c : INTEGER; prev : BOOLEAN; s : STRING) IS  -- the bank shows run r, columns 0..c-1
			VARIABLE ok : BOOLEAN := TRUE;
		BEGIN
			FOR k IN 0 TO c - 1 LOOP
				ra <= TO_UNSIGNED(k, 9);
				clocks(2);
				IF prev THEN
					ok := ok AND col(qp, r, k);
				ELSE
					ok := ok AND col(q, r, k);
				END IF;
			END LOOP;
			check(ok, s);
		END reads;

		PROCEDURE load1 (s : STD_LOGIC) IS
		BEGIN
			load <= '1';
			sv <= s;
			clocks(1);
			sv <= '0';
			clocks(2);
			load <= '0';
			clocks(2);
		END load1;
	BEGIN
		vb <= '1';
		load1('0');
		columns(1, 600);                                   -- case 1
		check(nv = 512, "nv after 600 columns");
		cv <= '1';
		reads(1, 100, FALSE, "comparison view: the first columns, not the ring");
		cv <= '0';
		ra <= TO_UNSIGNED(0, 9);
		clocks(2);
		check(col(q, 1, 512), "roll view: column 512 at address 0");
		load1('1');
		check(np = 512, "np after a run of 600 columns");
		cv <= '1';
		reads(1, 512, TRUE, "previous bank: the first 512 columns of run 1");

		columns(2, 100);                                   -- case 2
		reads(2, 100, FALSE, "comparison view: run 2 from address 0");
		cv <= '0';
		ra <= TO_UNSIGNED(0, 9);
		clocks(2);
		check(col(q, 2, 0), "roll view: the ring at address 0");
		cv <= '1';

		vb <= '0';                                         -- case 3, 5
		load1('1');
		check(np = 512 AND col(qp, 1, 0), "the banks swapped before vb");
		vb <= '1';
		clocks(1);
		check(np = 100, "np after a run of 100 columns");
		reads(2, 100, TRUE, "previous bank: run 2");
		columns(3, 10);
		reads(3, 10, FALSE, "run 3 writes the bank of run 1");
		reads(2, 100, TRUE, "run 3 overwrote run 2");

		load1('0');                                        -- case 4
		load1('1');
		check(np = 100, "a save with no column replaced the previous run");
		reads(2, 100, TRUE, "a save with no column changed the previous bank");

		rdy <= '0';                                        -- case 6
		columns(4, 1);
		clocks(200);
		check(nv = 0 AND wr = '0', "a column was written while rdy = 0");
		vb <= '0';
		rdy <= '1';
		clocks(5);
		check(nv = 0, "a column was written outside vb");
		vb <= '1';
		clocks(2);
		check(nv = 1, "the waiting column was lost");
		reads(4, 1, FALSE, "the waiting column");

		ASSERT errs = 0 REPORT "bank: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "bank: PASS, 512 of 600 kept, swap on save, empty run, vb, rdy";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
