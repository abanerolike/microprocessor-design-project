LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- Saturation cases of one plant_fast step that the vector windows never reach. Each case loads a state,
-- runs one step and checks only the output whose clamp it tests, with the expected value from the
-- integer model.
--   A, B: i1 at the top / bottom of Q(32,28) with v1 pushing further; i2 at the top / bottom and
--         vg = (1, 1) also drive pg past its 18 bits
--   C:    i2 re at the top, vg = (0.707, 0.707): the i2 operand clamps to 18 bits but pg does not, so a
--         missing operand clamp is not hidden behind the pg clamp
--   D, E: vc at the top / bottom with i2 at the other end, so the vc step pushes further out
--   F, G: vc and i2 at the top / bottom with vg against them, so the i2 step pushes further out
ENTITY plant_fast_edge_tb IS
END plant_fast_edge_tb;

ARCHITECTURE a OF plant_fast_edge_tb IS
	CONSTANT HI : SIGNED(31 DOWNTO 0) := (31 => '0', OTHERS => '1');
	CONSTANT LO : SIGNED(31 DOWNTO 0) := (31 => '1', OTHERS => '0');
	CONSTANT Z  : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL clk, load, step, slow : STD_LOGIC := '0';
	SIGNAL c : INTEGER RANGE 0 TO 49;
	SIGNAL done : BOOLEAN := FALSE;
	SIGNAL v1r, v1i : SIGNED(33 DOWNTO 0) := (OTHERS => '0');
	SIGNAL cg, sg, pg : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL i1r0, i1i0, vcr0, vci0, i2r0, i2i0, i1r, i1i, vcr, vci, i2r, i2i : SIGNED(31 DOWNTO 0) := Z;
BEGIN
	tm : ENTITY work.tick PORT MAP (clk, load, 0, c, step, slow);
	dut : ENTITY work.plant_fast PORT MAP (clk, load, step, c, v1r, v1i, cg, sg, i1r0, i1i0, vcr0, vci0, i2r0, i2i0,
		i1r, i1i, vcr, vci, i2r, i2i, pg);

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

		PROCEDURE go (a, b, d, e, f, g : SIGNED(31 DOWNTO 0); vr, vi : SIGNED(33 DOWNTO 0); vc, vs : INTEGER) IS
		BEGIN
			i1r0 <= a;
			i1i0 <= b;
			vcr0 <= d;
			vci0 <= e;
			i2r0 <= f;
			i2i0 <= g;
			v1r <= vr;
			v1i <= vi;
			cg <= TO_SIGNED(vc, 18);
			sg <= TO_SIGNED(vs, 18);
			load <= '1';
			WAIT UNTIL clk = '1' AND clk'EVENT;
			load <= '0';
			WAIT UNTIL clk = '1' AND clk'EVENT AND step = '1' FOR 51 * 20 ns;
			ASSERT step = '1' REPORT "timeout: no step pulse within 51 clocks" SEVERITY FAILURE;
			WAIT FOR 1 ns;
		END go;

		PROCEDURE check (ok : BOOLEAN; name : STRING) IS
		BEGIN
			IF NOT ok THEN
				errs := errs + 1;
				REPORT "case " & name & ": no clamp" SEVERITY ERROR;
			END IF;
		END check;
	BEGIN
		go(HI, LO, Z, Z, HI, HI, RESIZE(HI, 34) + HI, RESIZE(LO, 34) + LO, 65536, 65536);
		check(i1r = HI AND i1i = LO AND pg = 131071, "A, i1 and pg up");
		go(LO, HI, Z, Z, LO, LO, RESIZE(LO, 34) + LO, RESIZE(HI, 34) + HI, 65536, 65536);
		check(i1r = LO AND i1i = HI AND pg = -131072, "B, i1 and pg down");
		go(Z, Z, Z, Z, HI, Z, (OTHERS => '0'), (OTHERS => '0'), 46341, 46341);
		check(pg = 92681, "C, i2 operand");
		go(Z, Z, HI, HI, LO, LO, (OTHERS => '0'), (OTHERS => '0'), 0, 0);
		check(vcr = HI AND vci = HI, "D, vc up");
		go(Z, Z, LO, LO, HI, HI, (OTHERS => '0'), (OTHERS => '0'), 0, 0);
		check(vcr = LO AND vci = LO, "E, vc down");
		go(Z, Z, HI, HI, HI, HI, (OTHERS => '0'), (OTHERS => '0'), -65536, -65536);
		check(i2r = HI AND i2i = HI, "F, i2 up");
		go(Z, Z, LO, LO, LO, LO, (OTHERS => '0'), (OTHERS => '0'), 65536, 65536);
		check(i2r = LO AND i2i = LO, "G, i2 down");
		ASSERT errs = 0 REPORT "plant_fast edges: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "plant_fast edges: PASS, 7 cases";
		done <= TRUE;
		WAIT;
	END PROCESS;
END a;
