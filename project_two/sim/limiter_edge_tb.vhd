LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;

-- Boundary cases of the limiter from vectors/limcases.txt (made by the integer model): the decision
-- threshold below, at (1.0 pu only) and above, operand rounding, zero, each exponent change of the
-- normalizer, the four quadrants, no-limit mode and random inputs, with Imax changing between cases.
-- One case per step. Imax, en and the threshold t2 (formed here as the top level will do) are set at the
-- start of the step and held for it; ir is given from c = 11 (bit-inverted before). At the edge that ends
-- the step, lim, exc and il must equal the file.
ENTITY limiter_edge_tb IS
	GENERIC (fname : STRING := "vectors/limcases.txt");
END limiter_edge_tb;

ARCHITECTURE a OF limiter_edge_tb IS
	SIGNAL clk, load, step, slow, en, lim : STD_LOGIC := '0';
	SIGNAL c : INTEGER RANGE 0 TO 49;
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL imx : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL t2 : SIGNED(37 DOWNTO 0) := (OTHERS => '0');
	SIGNAL ir, il : work.gfm_pkg.words(0 TO 1) := (OTHERS => (OTHERS => '0'));
	SIGNAL exc : SIGNED(32 DOWNTO 0);
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, 0, c, step, slow);
	dut : ENTITY work.limiter PORT MAP (clk, en, c, imx, t2, ir, il, lim, exc);

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
		FILE fv : TEXT OPEN READ_MODE IS fname;
		VARIABLE l : LINE;
		VARIABLE n, errs, el, ee : INTEGER := 0;
		VARIABLE w32, r0, r1, e0, e1 : STD_LOGIC_VECTOR(31 DOWNTO 0);
		VARIABLE w33 : STD_LOGIC_VECTOR(32 DOWNTO 0);
		VARIABLE thr : SIGNED(31 DOWNTO 0);
	BEGIN
		load <= '1';
		WAIT UNTIL clk = '1' AND clk'EVENT;
		load <= '0';
		WHILE NOT endfile(fv) LOOP
			readline(fv, l);
			hrd(l, w32);
			read(l, ee);
			hrd(l, r0);
			hrd(l, r1);
			read(l, el);
			hrd(l, w33);
			hrd(l, e0);
			hrd(l, e1);
			imx <= SIGNED(w32);
			en <= '0';
			IF ee = 1 THEN
				en <= '1';
			END IF;
			thr := SIGNED(w32) - SHIFT_RIGHT(SIGNED(w32), 11);
			t2 <= RESIZE(SHIFT_RIGHT(thr * thr, 28), 38);
			ir <= (NOT SIGNED(r0), NOT SIGNED(r1));
			WAIT UNTIL clk = '1' AND clk'EVENT AND c = 10 FOR 51 * 20 ns;
			ir <= (SIGNED(r0), SIGNED(r1));
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 51 * 20 ns;
			ASSERT step = '1' REPORT "timeout: no step pulse within 51 clocks" SEVERITY FAILURE;
			IF (lim = '1') /= (el = 1) OR exc /= SIGNED(w33) OR il(0) /= SIGNED(e0) OR il(1) /= SIGNED(e1) THEN
				errs := errs + 1;
				REPORT "case " & INTEGER'IMAGE(n) & " wrong" SEVERITY ERROR;
			END IF;
			n := n + 1;
		END LOOP;
		ASSERT n = 198 AND errs = 0
			REPORT "limiter edges: FAIL, " & INTEGER'IMAGE(n) & " cases, " & INTEGER'IMAGE(errs) & " errors"
			SEVERITY FAILURE;
		REPORT "limiter edges: PASS, " & INTEGER'IMAGE(n) & " cases";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
