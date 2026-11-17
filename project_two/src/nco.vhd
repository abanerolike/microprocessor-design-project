LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE ieee.math_real.ALL;

-- Phase accumulator with sine and cosine for one angle.
-- The phase is 40 bits so a small speed error still moves it; the top 10 bits address a 1024-point sine
-- table and the next 16 bits interpolate between two neighbours. cos reads the same table 256 points on.
-- Inside a step: sin pair read at c = 0, cos pair at c = 1, so sn is valid from c = 2 and cs from c = 3,
-- both held to the end of the step. The phase takes inc at the edge that ends c = 49 and wraps.
ENTITY nco IS
	PORT (clk, load, step : IN STD_LOGIC;
		c   : IN INTEGER RANGE 0 TO 49;
		th0 : IN UNSIGNED(39 DOWNTO 0);
		inc : IN SIGNED(25 DOWNTO 0);
		th  : BUFFER UNSIGNED(39 DOWNTO 0) := (OTHERS => '0');
		cs, sn : OUT SIGNED(17 DOWNTO 0));
END nco;

ARCHITECTURE a OF nco IS
	TYPE table IS ARRAY (0 TO 1023) OF INTEGER RANGE -65536 TO 65536;

	-- sin at Q(18,16); every value is at least 0.003 LSB away from a rounding tie
	FUNCTION sine RETURN table IS
		VARIABLE t : table;
	BEGIN
		FOR i IN t'RANGE LOOP
			t(i) := INTEGER(ROUND(SIN(MATH_2_PI * REAL(i) / 1024.0) * 65536.0));
		END LOOP;
		RETURN t;
	END sine;

	CONSTANT rom : table := sine;
	SIGNAL adr : UNSIGNED(9 DOWNTO 0);
	SIGNAL r0, r1 : INTEGER RANGE -65536 TO 65536;
	SIGNAL v : SIGNED(17 DOWNTO 0);
BEGIN
	adr <= th(39 DOWNTO 30) + 256 WHEN c = 1 ELSE th(39 DOWNTO 30);
	-- r0 + (r1 - r0) * fraction, rounded half up; neighbours differ by at most 402
	v <= TO_SIGNED(r0, 18) + RESIZE(SHIFT_RIGHT(TO_SIGNED(r1 - r0, 11) * SIGNED('0' & th(29 DOWNTO 14)) + 32768, 16), 18);

	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			r0 <= rom(TO_INTEGER(adr));
			r1 <= rom(TO_INTEGER(adr + 1));
			IF c = 1 THEN
				sn <= v;
			END IF;
			IF c = 2 THEN
				cs <= v;
			END IF;
			IF load = '1' THEN
				th <= th0;
			ELSIF step = '1' THEN
				th <= th + UNSIGNED(RESIZE(inc, 40));
			END IF;
		END IF;
	END PROCESS;
END a;
