LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

-- One model step is 50 clocks of CLOCK_50 (1 us). c is the clock inside the step, so the step
-- schedule can start each operation at a fixed clock. Every state register is written at c = 49.
-- The grid model updates once every 1024 steps, in the step with k mod 1024 = 1023.
-- load sets the step position, so a test can start in the middle of a run.
ENTITY tick IS
	PORT (clk, load : IN STD_LOGIC;
		k0   : IN INTEGER RANGE 0 TO 1023;
		c    : OUT INTEGER RANGE 0 TO 49;
		step : OUT STD_LOGIC;
		slow : OUT STD_LOGIC);
END tick;

ARCHITECTURE a OF tick IS
	SIGNAL cnt : INTEGER RANGE 0 TO 49;
	SIGNAL k   : INTEGER RANGE 0 TO 1023;
BEGIN
	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			IF load = '1' THEN
				cnt <= 0;
				k <= k0;
			ELSIF cnt = 49 THEN
				cnt <= 0;
				IF k = 1023 THEN
					k <= 0;
				ELSE
					k <= k + 1;
				END IF;
			ELSE
				cnt <= cnt + 1;
			END IF;
		END IF;
	END PROCESS;

	c <= cnt;
	step <= '1' WHEN cnt = 49 ELSE '0';
	slow <= '1' WHEN k = 1023 ELSE '0';
END a;
