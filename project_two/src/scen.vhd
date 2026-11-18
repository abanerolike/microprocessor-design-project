LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Board settings and scenario inputs of the core.
--   KEY0 held: the core reloads its start state and SW0..4 are read; they stay fixed after release.
--   KEY0, KEY1, SW0..4 and SW17 (page, pg) pass two flip-flops first; at power-up the core stays in
--   reset until the switch flip-flops hold real values.
--   SW0 fb; SW2:1 limit mode 00 1.2 pu, 01 1.2 pu then 1.0 pu 10 s after the trip, 10 no limit,
--   11 reserved (err = 1, the core stays in reset until a reset with a valid mode); SW3 trip A (1.4 GW)
--   instead of trip B (3.3 GW); SW4 automatic trip at 1 s (KEY1 ignored), else a trip at the next step
--   after a KEY1 press. The trip happens once.
--   Every scenario value changes only at a step edge. Trip time, the 0.01 s timer t and the limit change
--   count model steps, so they keep model time if the model is ever slowed down.
--   Records until the next reset: xmin (lowest x from the trip on), seen (the limiter has acted).
--   t stops at 10000 (100 s or more), which the display shows as out of range.
ENTITY scen IS
	GENERIC (kt : INTEGER := SKT; nc : INTEGER := SNC; nw : INTEGER := SNW);
	PORT (clk, step, lim : IN STD_LOGIC;
		key  : IN STD_LOGIC_VECTOR(1 DOWNTO 0);      -- KEY1, KEY0, active low
		sw   : IN STD_LOGIC_VECTOR(4 DOWNTO 0);
		page : IN STD_LOGIC;
		x    : IN SIGNED(31 DOWNTO 0);
		load : BUFFER STD_LOGIC;
		dp, cap, p0, imx : OUT SIGNED(31 DOWNTO 0);
		pg0, ks : OUT SIGNED(17 DOWNTO 0);
		t2   : OUT SIGNED(37 DOWNTO 0);
		en   : OUT STD_LOGIC;
		lm   : BUFFER INTEGER RANGE 0 TO 3;
		pg, fb, ta, au, err, tr, sh, seen, blink : BUFFER STD_LOGIC;
		xmin : BUFFER SIGNED(31 DOWNTO 0);
		t    : BUFFER INTEGER RANGE 0 TO 10000);     -- 0.01 s since the trip
END scen;

ARCHITECTURE a OF scen IS
	FUNCTION th2 (m : INTEGER) RETURN SIGNED IS      -- limit threshold for m2, ((m - m/2048)^2) >> 28
		VARIABLE v : SIGNED(31 DOWNTO 0) := TO_SIGNED(m, 32) - SHIFT_RIGHT(TO_SIGNED(m, 32), 11);
	BEGIN
		RETURN RESIZE(SHIFT_RIGHT(v * v, 28), 38);
	END th2;
	SIGNAL r1, r2, k1, k2, k3, p1, pend : STD_LOGIC := '0';
	SIGNAL s1, s2 : STD_LOGIC_VECTOR(4 DOWNTO 0) := (OTHERS => '0');
	SIGNAL up : STD_LOGIC_VECTOR(2 DOWNTO 0) := "000";   -- 111 once s2 holds sampled switches
	SIGNAL kc : INTEGER RANGE 0 TO kt - 1 := 0;
	SIGNAL pc : INTEGER RANGE 0 TO nc - 1 := 0;
	SIGNAL bc : UNSIGNED(17 DOWNTO 0) := (OTHERS => '0');
BEGIN
	load <= r2 OR NOT up(2) OR err;
	err <= '1' WHEN lm = 3 ELSE '0';
	blink <= bc(17);
	p0 <= TO_SIGNED(SP0, 32);
	cap <= TO_SIGNED(SCP, 32);
	pg0 <= TO_SIGNED(SPG, 18);
	sh <= '1' WHEN lm = 1 AND t >= nw ELSE '0';
	dp <= (OTHERS => '0') WHEN tr = '0' ELSE TO_SIGNED(SDA, 32) WHEN ta = '1' ELSE TO_SIGNED(SDP, 32);
	ks <= TO_SIGNED(SKS, 18) WHEN fb = '1' ELSE (OTHERS => '0');
	en <= '0' WHEN lm = 2 ELSE '1';
	imx <= TO_SIGNED(2 ** 28, 32) WHEN lm = 2 ELSE TO_SIGNED(SI1, 32) WHEN sh = '1' ELSE TO_SIGNED(SI0, 32);
	t2 <= th2(2 ** 28) WHEN lm = 2 ELSE th2(SI1) WHEN sh = '1' ELSE th2(SI0);

	PROCESS (clk)
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			r1 <= NOT key(0);                        -- two flip-flops against metastability
			r2 <= r1;
			k1 <= NOT key(1);
			k2 <= k1;
			k3 <= k2;                                -- k2 AND NOT k3: one-clock KEY1 press
			s1 <= sw;
			s2 <= s1;
			p1 <= page;
			pg <= p1;
			up <= up(1 DOWNTO 0) & '1';
			IF r2 = '1' OR up(2) = '0' THEN
				fb <= s2(0);
				lm <= TO_INTEGER(UNSIGNED(s2(2 DOWNTO 1)));
				ta <= s2(3);
				au <= s2(4);
			END IF;
			IF load = '1' THEN
				tr <= '0';
				pend <= '0';
				seen <= '0';
				kc <= 0;
				pc <= 0;
				t <= 0;
				bc <= (OTHERS => '0');
			ELSE
				IF k2 = '1' AND k3 = '0' THEN
					pend <= '1';
				END IF;
				IF step = '1' THEN                   -- the edge that ends a model step
					bc <= bc + 1;
					IF lim = '1' THEN
						seen <= '1';
					END IF;
					IF tr = '0' THEN
						xmin <= x;
						IF (au = '1' AND kc = kt - 1) OR (au = '0' AND (pend = '1' OR (k2 = '1' AND k3 = '0'))) THEN
							tr <= '1';
						END IF;
						IF kc < kt - 1 THEN
							kc <= kc + 1;
						END IF;
					ELSE
						IF x < xmin THEN
							xmin <= x;
						END IF;
						IF pc < nc - 1 THEN
							pc <= pc + 1;
						ELSE
							pc <= 0;
							IF t < 10000 THEN
								t <= t + 1;
							END IF;
						END IF;
					END IF;
				END IF;
			END IF;
		END IF;
	END PROCESS;
END a;
