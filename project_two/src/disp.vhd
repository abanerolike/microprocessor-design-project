LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE work.gfm_pkg.ALL;

-- HEX display. pg = 0: HEX7..4 frequency, HEX3..0 lowest frequency after the trip (0.01 Hz).
-- pg = 1: HEX7..4 load shed (0.01 GW), HEX3..0 time since the trip (0.01 s). Before the trip HEX3..0
-- show ----. The board has no decimal point, so every value has four digits (0480 = 4.80 GW); a value
-- outside 0..9999 shows Err instead of wrapping or sticking at a limit.
--   f = 60 (1 + x) Hz -> 6000 + 6000 x; shed in pu of 80 GVA -> 8000 shed. x and shed are Q31.
-- Every 0.1 s of real time (5,000,000 clocks) the inputs are copied at once, on the clock right after a
-- step edge (all core states and records written at that edge). The shown lowest frequency is the lower
-- of the copied x and xmin, since xmin takes x one step later. One 32 x 14 multiplier and one
-- shift-add-3 converter serve the four values in turn: 16 clocks each (b = 0 product, 1 load and range
-- check, 2..15 one bit per clock). The digits go to the display together when all four are done, so
-- the eight digits always come from the same copy.
ENTITY disp IS
	GENERIC (nr : INTEGER := 5000000);              -- must be longer than one round (64) plus one step
	PORT (clk, step, pg, tr : IN STD_LOGIC;
		x, xmin, shed : IN SIGNED(31 DOWNTO 0);
		t   : IN INTEGER RANGE 0 TO 10000;
		hex : OUT segs);
END disp;

ARCHITECTURE a OF disp IS
	TYPE nums IS ARRAY (0 TO 3) OF UNSIGNED(3 DOWNTO 0);      -- digit 0 = ones
	TYPE sets IS ARRAY (0 TO 3) OF nums;                      -- f, lowest f, shed, time
	TYPE pats IS ARRAY (0 TO 3) OF STD_LOGIC_VECTOR(6 DOWNTO 0);
	CONSTANT DASH : STD_LOGIC_VECTOR(6 DOWNTO 0) := "0111111";
	CONSTANT ERR : pats := ("1111111", "0101111", "0101111", "0000110");   -- "Err ", digit 0 first
	FUNCTION seg (d : UNSIGNED(3 DOWNTO 0)) RETURN STD_LOGIC_VECTOR IS
	BEGIN
		CASE TO_INTEGER(d) IS
			WHEN 0 => RETURN "1000000";
			WHEN 1 => RETURN "1111001";
			WHEN 2 => RETURN "0100100";
			WHEN 3 => RETURN "0110000";
			WHEN 4 => RETURN "0011001";
			WHEN 5 => RETURN "0010010";
			WHEN 6 => RETURN "0000010";
			WHEN 7 => RETURN "1111000";
			WHEN 8 => RETURN "0000000";
			WHEN OTHERS => RETURN "0010000";
		END CASE;
	END seg;
	SIGNAL dg, hd : sets := (OTHERS => (OTHERS => "0000"));         -- being converted, shown
	SIGNAL bad, hb : STD_LOGIC_VECTOR(0 TO 3) := (OTHERS => '0');
	SIGNAL due, sp, cp, htr : STD_LOGIC := '0';
	SIGNAL rc : INTEGER RANGE 0 TO nr - 1 := 0;
	SIGNAL sx, sxm, ssh : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL st : INTEGER RANGE 0 TO 10000 := 0;
	SIGNAL str : STD_LOGIC := '0';
	SIGNAL j : INTEGER RANGE 0 TO 3 := 0;
	SIGNAL b : INTEGER RANGE 0 TO 15 := 0;
	SIGNAL m : SIGNED(31 DOWNTO 0);
	SIGNAL kf : SIGNED(13 DOWNTO 0);
	SIGNAL p : SIGNED(45 DOWNTO 0);
	SIGNAL v : UNSIGNED(13 DOWNTO 0);
	SIGNAL bcd : UNSIGNED(15 DOWNTO 0);
BEGIN
	m <= sx WHEN j = 0 OR (j = 1 AND sx < sxm) ELSE sxm WHEN j = 1 ELSE ssh;
	kf <= TO_SIGNED(6000, 14) WHEN j < 2 ELSE TO_SIGNED(8000, 14);

	PROCESS (clk)
		VARIABLE q : SIGNED(15 DOWNTO 0);
		VARIABLE d : UNSIGNED(15 DOWNTO 0);
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			p <= m * kf;
			sp <= step;
			cp <= '0';
			IF cp = '1' THEN
				hd <= dg;
				hb <= bad;
				htr <= str;
			END IF;
			IF b = 1 THEN
				q := RESIZE(rs(p, 31), 16);
				IF j < 2 THEN
					q := q + 6000;
				ELSIF j = 3 THEN
					q := TO_SIGNED(st, 16);
				END IF;
				bad(j) <= '0';
				IF q < 0 OR q > 9999 THEN
					bad(j) <= '1';
				END IF;
				v <= UNSIGNED(q(13 DOWNTO 0));
				bcd <= (OTHERS => '0');
			ELSIF b > 1 THEN
				d := bcd;
				FOR i IN 0 TO 3 LOOP                     -- add 3 to each digit of 5 or more, then shift
					IF d(4 * i + 3 DOWNTO 4 * i) >= 5 THEN
						d(4 * i + 3 DOWNTO 4 * i) := d(4 * i + 3 DOWNTO 4 * i) + 3;
					END IF;
				END LOOP;
				d := d(14 DOWNTO 0) & v(13);
				bcd <= d;
				v <= v(12 DOWNTO 0) & '0';
				IF b = 15 THEN
					FOR i IN 0 TO 3 LOOP
						dg(j)(i) <= d(4 * i + 3 DOWNTO 4 * i);
					END LOOP;
					IF j = 3 THEN
						cp <= '1';
					END IF;
					j <= (j + 1) MOD 4;
				END IF;
			END IF;
			b <= (b + 1) MOD 16;
			rc <= (rc + 1) MOD nr;
			IF rc = 0 THEN
				due <= '1';
			END IF;
			IF due = '1' AND sp = '1' THEN           -- copy, then start a new round; a round that ends
				cp <= '0';                           -- on this clock belongs to the old copy: drop it
				sx <= x;
				sxm <= xmin;
				ssh <= shed;
				st <= t;
				str <= tr;
				due <= '0';
				j <= 0;
				b <= 0;
			END IF;
		END IF;
	END PROCESS;

	g : FOR i IN 0 TO 3 GENERATE
		hex(i + 4) <= ERR(i) WHEN (pg = '0' AND hb(0) = '1') OR (pg = '1' AND hb(2) = '1')
			ELSE seg(hd(0)(i)) WHEN pg = '0' ELSE seg(hd(2)(i));
		hex(i) <= DASH WHEN htr = '0' ELSE ERR(i) WHEN (pg = '0' AND hb(1) = '1') OR (pg = '1' AND hb(3) = '1')
			ELSE seg(hd(1)(i)) WHEN pg = '0' ELSE seg(hd(3)(i));
	END GENERATE;
END a;
