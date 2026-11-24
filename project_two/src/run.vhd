LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

-- Pause, single steps and slow motion. The model holds at c = 45 of a step while go = 0 (see tick): no
-- block writes there, so it goes on bit for bit the same. Some states already hold part of the next
-- step (shed and the UFLS stages at c = 12..18), so the displays show the values of the last edge.
--   SW7 = 1: pause. While paused and not stepping, KEY2 runs until the graph column being collected is
--   complete (ce marks its last step, so a press in the middle of a column runs only the rest of it),
--   KEY3 runs n3 steps (0.1 s of model time). Presses while a step run is going are ignored.
--   SW9:8 slow motion: each step waits until (wt + 1) x 50 clocks have passed since the last step edge,
--   wt = 0, 3, 9, 99 for x1, x1/4, x1/10, x1/100. The switches act at once (between two steps).
--   KEY2, KEY3 and SW7..9 pass two flip-flops; a press is one clock long (edge detector).
ENTITY run IS
	GENERIC (n3 : INTEGER := 100000);
	PORT (clk, load, step, ce : IN STD_LOGIC;
		key : IN STD_LOGIC_VECTOR(1 DOWNTO 0);            -- KEY3, KEY2, active low
		sw  : IN STD_LOGIC_VECTOR(2 DOWNTO 0);            -- SW9..7
		go  : OUT STD_LOGIC;
		ps, bz : BUFFER STD_LOGIC;                        -- paused, a step run is going
		sl  : OUT INTEGER RANGE 0 TO 3);                  -- slow motion setting
END run;

ARCHITECTURE a OF run IS
	TYPE waits IS ARRAY (0 TO 3) OF INTEGER;
	CONSTANT WT : waits := (45, 195, 495, 4995);         -- c = 45 plus the extra clocks of the setting
	SIGNAL s1, s2 : STD_LOGIC_VECTOR(2 DOWNTO 0) := "000";
	SIGNAL k1, k2, k3 : STD_LOGIC_VECTOR(1 DOWNTO 0) := "00";
	SIGNAL wc : INTEGER RANGE 0 TO 4995 := 0;           -- clocks since the last step edge
	SIGNAL col : STD_LOGIC := '0';                      -- the step run is KEY2 (to the column end)
	SIGNAL n : INTEGER RANGE 0 TO n3 := 0;
	SIGNAL v : INTEGER RANGE 0 TO 3;
BEGIN
	ps <= s2(0);
	WITH s2(2 DOWNTO 1) SELECT v <= 0 WHEN "00", 1 WHEN "01", 2 WHEN "10", 3 WHEN OTHERS;
	sl <= v;
	go <= '1' WHEN wc >= WT(v) AND (ps = '0' OR bz = '1') ELSE '0';

	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			s1 <= sw;
			s2 <= s1;
			k1 <= NOT key;
			k2 <= k1;
			k3 <= k2;
			IF step = '1' THEN
				wc <= 0;
			ELSIF wc < 4995 THEN
				wc <= wc + 1;
			END IF;
			IF load = '1' OR ps = '0' THEN
				bz <= '0';
			ELSIF bz = '0' AND k2(0) = '1' AND k3(0) = '0' THEN
				bz <= '1';
				col <= '1';
			ELSIF bz = '0' AND k2(1) = '1' AND k3(1) = '0' THEN
				bz <= '1';
				col <= '0';
				n <= n3;
			ELSIF bz = '1' AND step = '1' THEN
				IF col = '1' AND ce = '1' THEN
					bz <= '0';
				END IF;
				IF col = '0' THEN
					n <= n - 1;
					IF n = 1 THEN
						bz <= '0';
					END IF;
				END IF;
			END IF;
		END IF;
	END PROCESS;
END a;
