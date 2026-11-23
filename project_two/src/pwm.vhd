LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- Three-phase PWM of the converter, one CLOCK_50 tick per clock: 50 ticks per model step, a 4 kHz
-- triangle carrier (0..6250..1), double update and 2 us dead time. The LCL takes the mean phase voltage
-- of the last step, so the controller voltage reaches the plant two steps later (v1 one step, the mean
-- voltage one more), plus the wait for the next carrier end.
--   duty = 3125 + ceil(p 6250 / vdc) for the phase voltages p of v1 at the nominal angle, clipped to
--          0..6250; a leg is on while its duty is above the carrier
--   a switch turns on 100 ticks after its command and off at once; meanwhile the leg follows the
--          phase current: negative -> +vdc/2, else -vdc/2
--   u = e^(-j phi) (vdc / 150 (2 na - nb - nc) + j sqrt(3) vdc / 150 (nb - nc)) from the counts n of
--          ticks with the leg at +vdc/2 (the mean of the three legs cancels in this sum)
-- Schedule of the one multiplier in step k (c = clock in the step):
--   0..5   u(k-1) from the counts of step k-1 at phi(k-1); u is valid from c = 7
--   33..42 the duty pending for step k+1 from v1(k) at phi(k+1)
--   43..48 the current signs for step k+1 from the plant's new i1 (= i1(k+1)) at phi(k+1)
-- At the edge that ends c = 49: the signs, the counts and the angles move on, and when step k+1 starts
-- at a carrier end the pending duty becomes active, so its first tick already compares with it.
-- en = 0 holds every register (the rest of the model must hold c and its inputs too); load wins over en.
ENTITY pwm IS
	PORT (clk, load, en, vs : IN STD_LOGIC;                 -- vs: vdc 2.4 pu (0) or 4.0 pu (1)
		c        : IN INTEGER RANGE 0 TO 49;
		v1r, v1i : IN SIGNED(33 DOWNTO 0);                   -- controller voltage, Q28, valid from c = 33
		n1r, n1i : IN SIGNED(31 DOWNTO 0);                   -- plant's new i1, Q28, from c = 36 and 37
		q0       : IN INTEGER RANGE 0 TO 249;                -- start: step in the carrier period
		th0      : IN UNSIGNED(39 DOWNTO 0);                 -- start: nominal phase of the next step
		c0, s0   : IN SIGNED(17 DOWNTO 0);                   -- start: cos and sin of this step's phase
		da0, dp0 : IN duties;                                -- start: active and pending duty
		dc0      : IN deads;
		cm0, ng0 : IN STD_LOGIC_VECTOR(0 TO 2);              -- start: gate commands, current signs
		ur0, ui0 : IN SIGNED(33 DOWNTO 0);                   -- start: u for the first step
		ur, ui   : BUFFER SIGNED(33 DOWNTO 0);               -- mean phase voltage for the LCL, Q28
		leg      : BUFFER STD_LOGIC_VECTOR(0 TO 2);          -- last tick: leg at +vdc/2
		cmd, ng  : BUFFER STD_LOGIC_VECTOR(0 TO 2);
		dact, dpen : BUFFER duties;
		dct      : BUFFER deads;
		th       : BUFFER UNSIGNED(39 DOWNTO 0));
END pwm;

ARCHITECTURE a OF pwm IS
	TYPE counts3 IS ARRAY (0 TO 2) OF INTEGER RANGE 0 TO 50;
	TYPE consts IS ARRAY (STD_LOGIC RANGE '0' TO '1') OF INTEGER;
	CONSTANT VK : consts := (83333, 50000);                  -- 6250 / vdc, F 5
	CONSTANT U1 : consts := (33554, 55924);                  -- vdc / 150, F 21
	CONSTANT U2 : consts := (58118, 96863);                  -- sqrt(3) vdc / 150, F 21
	CONSTANT H3 : INTEGER := 113512;                         -- sqrt(3) / 2, F 17
	CONSTANT KN2 : SIGNED(25 DOWNTO 0) := TO_SIGNED(32985344, 26);
	SIGNAL tq : INTEGER RANGE 0 TO 12499;                    -- tick in the carrier period
	SIGNAL cr : INTEGER RANGE 0 TO 6250;
	SIGNAL n, nn : counts3;                                  -- counts of this and of the last step
	SIGNAL first : STD_LOGIC;
	SIGNAL cs, sn, c1, s1, c2, s2 : SIGNED(17 DOWNTO 0);     -- angles: next step (nco), this, last
	SIGNAL mx : SIGNED(19 DOWNTO 0);
	SIGNAL my : SIGNED(17 DOWNTO 0);
	SIGNAL p : SIGNED(37 DOWNTO 0);
	SIGNAL acc : SIGNED(37 DOWNTO 0);
	SIGNAL gr, gi, wr, wi, h, r, ri : SIGNED(19 DOWNTO 0);
	SIGNAL a, b, hw : SIGNED(19 DOWNTO 0);
	SIGNAL st : STD_LOGIC;

	FUNCTION v18 (v : SIGNED; f : NATURAL) RETURN SIGNED IS  -- operand: shift with rounding, clamp
	BEGIN
		RETURN RESIZE(sat(rs(RESIZE(v, v'LENGTH + 1), f), 18), 20);
	END v18;
BEGIN
	-- nominal angle one step ahead; the step 65,970,688 needs 27 bits, so half of it goes in twice
	st <= en WHEN c = 24 OR c = 49 ELSE '0';
	ns : ENTITY work.nco PORT MAP (clk, load, st, c, th0, KN2, th, cs, sn, en);

	cr <= tq WHEN tq <= 6250 ELSE 12500 - tq;
	a <= v18(v1r, 12) WHEN c < 43 ELSE v18(n1r, 14);
	b <= v18(v1i, 12) WHEN c < 43 ELSE v18(n1i, 14);
	hw <= rs(wr, 1);
	WITH c SELECT mx <=
		TO_SIGNED(2 * nn(0) - nn(1) - nn(2), 20) WHEN 0, TO_SIGNED(nn(1) - nn(2), 20) WHEN 1,
		gr WHEN 2 | 5, gi WHEN 3 | 4, a WHEN 33 | 35 | 43 | 45, b WHEN 34 | 36 | 44 | 46, wi WHEN 38,
		wr WHEN 40, h - hw WHEN 41, -h - hw WHEN 42, ri WHEN OTHERS;
	WITH c SELECT my <=
		TO_SIGNED(U1(vs), 18) WHEN 0, TO_SIGNED(U2(vs), 18) WHEN 1, c2 WHEN 2 | 4, s2 WHEN 3 | 5,
		cs WHEN 33 | 36 | 43 | 46, sn WHEN 34 | 35 | 44 | 45, TO_SIGNED(VK(vs), 18) WHEN 40 | 41 | 42,
		TO_SIGNED(H3, 18) WHEN OTHERS;

	PROCESS (clk)
		VARIABLE d : INTEGER RANGE 0 TO 100;
		VARIABLE cm, hi : STD_LOGIC;
		VARIABLE m : counts3;
		VARIABLE v, w : SIGNED(37 DOWNTO 0);
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			IF load = '1' THEN
				tq <= 50 * q0;
				dact <= da0;
				dpen <= dp0;
				dct <= dc0;
				cmd <= cm0;
				ng <= ng0;
				ur <= ur0;
				ui <= ui0;
				c1 <= c0;
				s1 <= s0;
				n <= (OTHERS => 0);
				first <= '1';
			ELSIF en = '1' THEN
				FOR x IN 0 TO 2 LOOP                      -- one tick of each leg
					cm := '0';
					IF dact(x) > cr THEN
						cm := '1';
					END IF;
					d := dct(x);
					IF cm /= cmd(x) THEN
						d := 0;
					END IF;
					hi := ng(x);
					IF d = 100 THEN
						hi := cm;
					END IF;
					cmd(x) <= cm;
					dct(x) <= d;
					IF d < 100 THEN
						dct(x) <= d + 1;
					END IF;
					leg(x) <= hi;
					m(x) := n(x);
					IF hi = '1' THEN
						m(x) := n(x) + 1;
					END IF;
				END LOOP;
				n <= m;
				IF tq = 12499 THEN
					tq <= 0;
				ELSE
					tq <= tq + 1;
				END IF;

				p <= mx * my;
				CASE c IS                                -- each line uses the product formed one clock before
					WHEN 1 => gr <= RESIZE(rs(p, 6), 20);
					WHEN 2 => gi <= RESIZE(rs(p, 6), 20);
					WHEN 3 | 5 | 34 | 36 | 44 | 46 => acc <= p;
					WHEN 4 =>
						IF first = '0' THEN
							ur <= RESIZE(rs(acc + p, 3), 34);
						END IF;
					WHEN 6 =>
						IF first = '0' THEN
							ui <= RESIZE(rs(acc - p, 3), 34);
						END IF;
					WHEN 35 => wr <= RESIZE(rs(acc - p, 16), 20);
					WHEN 37 => wi <= RESIZE(rs(acc + p, 16), 20);
					WHEN 39 => h <= RESIZE(rs(p, 17), 20);
					WHEN 41 | 42 | 43 =>                     -- 3125 + ceil(p / 2^21), clipped
						v := SHIFT_RIGHT(p + 2097151, 21) + 3125;
						IF v < 0 THEN
							v := (OTHERS => '0');
						ELSIF v > 6250 THEN
							v := TO_SIGNED(6250, 38);
						END IF;
						dpen(c - 41) <= TO_INTEGER(v);
					WHEN 45 => r <= RESIZE(rs(acc - p, 16), 20);
					WHEN 47 => ri <= RESIZE(rs(acc + p, 16), 20);
					WHEN 49 =>                               -- signs of the phase currents a, b, c
						v := p - SHIFT_LEFT(RESIZE(r, 38), 16);
						w := -p - SHIFT_LEFT(RESIZE(r, 38), 16);
						ng <= (r(19), v(37), w(37));
						n <= (OTHERS => 0);
						nn <= m;
						first <= '0';
						c1 <= cs;
						s1 <= sn;
						c2 <= c1;
						s2 <= s1;
						IF tq = 6249 OR tq = 12499 THEN
							dact <= dpen;
						END IF;
					WHEN OTHERS => NULL;
				END CASE;
			END IF;
		END IF;
	END PROCESS;
END a;
