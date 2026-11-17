LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE std.textio.ALL;
USE work.tb_util.ALL;

-- hrd at the widths that are not a multiple of 4: largest value, -1 and smallest value of each width.
ENTITY hrd_tb IS
END hrd_tb;

ARCHITECTURE a OF hrd_tb IS
BEGIN
	PROCESS
		VARIABLE errs : INTEGER := 0;

		PROCEDURE check (s : STRING; w : INTEGER) IS
			VARIABLE l : LINE := NEW STRING'(s);
			VARIABLE v, ones, top : STD_LOGIC_VECTOR(w - 1 DOWNTO 0);
		BEGIN
			ones := (OTHERS => '1');
			top := (OTHERS => '0');
			top(w - 1) := '1';
			hrd(l, v);
			IF v /= (NOT top) THEN errs := errs + 1; REPORT "largest value, width " & INTEGER'IMAGE(w) SEVERITY ERROR; END IF;
			hrd(l, v);
			IF v /= ones THEN errs := errs + 1; REPORT "-1, width " & INTEGER'IMAGE(w) SEVERITY ERROR; END IF;
			hrd(l, v);
			IF v /= top THEN errs := errs + 1; REPORT "smallest value, width " & INTEGER'IMAGE(w) SEVERITY ERROR; END IF;
		END check;
	BEGIN
		check("1ffff 3ffff 20000", 18);
		check("0ffffff 1ffffff 1000000", 25);
		check("1ffffff 3ffffff 2000000", 26);
		check("0ffffffff 1ffffffff 100000000", 33);
		check("1ffffffff 3ffffffff 200000000", 34);
		ASSERT errs = 0 REPORT "hrd: FAIL, " & INTEGER'IMAGE(errs) & " errors" SEVERITY FAILURE;
		REPORT "hrd: PASS, 15 values at widths 18, 25, 26, 33, 34";
		WAIT;
	END PROCESS;
END a;
