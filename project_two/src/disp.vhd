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
-- shift-add-3 converter serve the five values in turn: 16 clocks each (b = 0 product, 1 load and range
-- check, 2..15 one bit per clock). The digits go to the display together when all five are done, so
-- the eight digits always come from the same copy. The same shown copy goes to the VGA text: digits,
-- flags, trip flag and the lowest x as it was copied (for the 59.2 / 59.7 Hz check).
-- Fifth value, for the VGA text only: PK, the largest |i1| of the plant state since the trip, in 0.001 pu.
-- On the clock after each step edge i1 is taken as the 18-bit Q14 operand (rounded, clamped), squared
-- on the next clock and kept if larger on the one after, with the trip flag of the same step taken
-- along. Three clocks after a copy the largest square is taken too, so it holds the samples up to the
-- copied step and no later; its root (Q16, bit by bit in 20 clocks, no multiplier) times 1000, rounded,
-- is the fifth value. load clears PK, drops the round running and at once shows the values as before the
-- trip (dashes), until the next copy.
-- Comparison: ce marks the last step of a graph column. Its end edge takes a copy at once (cm, a refresh
-- that is due waits), its round runs with nothing else copied (cr, rdy low) and gives c1; the recorder
-- writes the column only then, and wr keeps c1 as c2, the last column written to the comparison bank
-- (the first 512 of the run; later columns do not change c2). A save (sv) keeps c2 as pv when the run
-- has one, or c1 when its column is written with the save (wr on the same clock). While the model is
-- held (fz) the 0.1 s refresh goes on without a step edge, from the inputs kept at the last edge (or
-- at the load, before the first edge of a run); a column copy still waits for the edge.
ENTITY disp IS
	GENERIC (nr : INTEGER := 5000000);              -- must be longer than one round (80) plus one step
	PORT (clk, load, step, pg, tr : IN STD_LOGIC;
		x, xmin, shed, ir, ii : IN SIGNED(31 DOWNTO 0);  -- ir, ii: i1, Q28
		t   : IN INTEGER RANGE 0 TO 10000;
		hex : OUT segs;
		dd  : OUT STD_LOGIC_VECTOR(79 DOWNTO 0);       -- the shown digits, value v digit i at 16 v + 4 i
		db  : OUT STD_LOGIC_VECTOR(0 TO 4);           -- the shown out-of-range flags
		dt  : OUT STD_LOGIC;                           -- the shown trip flag
		lo  : OUT SIGNED(31 DOWNTO 0);                 -- lowest x of the shown copy, not rounded
		fz, ce, wr, sv : IN STD_LOGIC := '0';          -- model held, last step of a column, column written, save
		set : IN STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
		rdy : OUT STD_LOGIC;                           -- no column copy waiting or being converted
		pv  : BUFFER shown := NONE);                   -- the kept copy of the previous run
END disp;

ARCHITECTURE a OF disp IS
	TYPE nums IS ARRAY (0 TO 3) OF UNSIGNED(3 DOWNTO 0);      -- digit 0 = ones
	TYPE sets IS ARRAY (0 TO 4) OF nums;                      -- f, lowest f, shed, time, PK
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
	SIGNAL bad, hb : STD_LOGIC_VECTOR(0 TO 4) := (OTHERS => '0');
	SIGNAL due, sp, cp, htr : STD_LOGIC := '0';
	SIGNAL hm : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL rc : INTEGER RANGE 0 TO nr - 1 := 0;
	SIGNAL sx, sxm, ssh : SIGNED(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL st : INTEGER RANGE 0 TO 10000 := 0;
	SIGNAL str : STD_LOGIC := '0';
	SIGNAL j : INTEGER RANGE 0 TO 4 := 0;
	SIGNAL pa, pb : SIGNED(17 DOWNTO 0) := (OTHERS => '0');
	SIGNAL pt, pt2 : STD_LOGIC := '0';
	SIGNAL sq, pk : UNSIGNED(35 DOWNTO 0) := (OTHERS => '0');
	SIGNAL w : INTEGER RANGE 0 TO 24 := 0;                    -- clocks since the copy, root steps
	SIGNAL rad : UNSIGNED(39 DOWNTO 0) := (OTHERS => '0');
	SIGNAL rm : UNSIGNED(23 DOWNTO 0) := (OTHERS => '0');
	SIGNAL root : UNSIGNED(19 DOWNTO 0) := (OTHERS => '0');
	SIGNAL b : INTEGER RANGE 0 TO 15 := 0;
	SIGNAL m : SIGNED(31 DOWNTO 0);
	SIGNAL kf : SIGNED(13 DOWNTO 0);
	SIGNAL p : SIGNED(45 DOWNTO 0);
	SIGNAL v : UNSIGNED(13 DOWNTO 0);
	SIGNAL bcd : UNSIGNED(15 DOWNTO 0);
	SIGNAL ce1, cm, cr : STD_LOGIC := '0';                     -- column copy: asked, its round running
	SIGNAL c1, c2 : shown := NONE;                             -- copy of the last column, of the last written one
	SIGNAL lx, lxm, lsh : SIGNED(31 DOWNTO 0) := (OTHERS => '0');    -- the inputs at the last step edge
	SIGNAL lt : INTEGER RANGE 0 TO 10000 := 0;
	SIGNAL ltr : STD_LOGIC := '0';

	FUNCTION dig (h : sets) RETURN STD_LOGIC_VECTOR IS
		VARIABLE r : STD_LOGIC_VECTOR(79 DOWNTO 0);
	BEGIN
		FOR k IN 0 TO 4 LOOP
			FOR i IN 0 TO 3 LOOP
				r(16 * k + 4 * i + 3 DOWNTO 16 * k + 4 * i) := STD_LOGIC_VECTOR(h(k)(i));
			END LOOP;
		END LOOP;
		RETURN r;
	END dig;
BEGIN
	m <= sx WHEN j = 0 OR (j = 1 AND sx < sxm) ELSE sxm WHEN j = 1 ELSE SIGNED(RESIZE(root, 32)) WHEN j = 4
		ELSE ssh;
	kf <= TO_SIGNED(6000, 14) WHEN j < 2 ELSE TO_SIGNED(1000, 14) WHEN j = 4 ELSE TO_SIGNED(8000, 14);

	PROCESS (clk)
		VARIABLE q : SIGNED(15 DOWNTO 0);
		VARIABLE d : UNSIGNED(15 DOWNTO 0);
		VARIABLE e : UNSIGNED(23 DOWNTO 0);
	BEGIN
		IF clk = '1' AND clk'EVENT THEN
			p <= m * kf;
			sp <= step;
			cp <= '0';
			IF cp = '1' THEN
				hd <= dg;
				hb <= bad;
				htr <= str;
				hm <= sxm;
				IF sx < sxm THEN
					hm <= sx;
				END IF;
			END IF;
			IF b = 1 THEN
				q := RESIZE(rs(p, 31), 16);
				IF j < 2 THEN
					q := q + 6000;
				ELSIF j = 3 THEN
					q := TO_SIGNED(st, 16);
				ELSIF j = 4 THEN
					q := RESIZE(rs(p, 16), 16);           -- root Q16 x 1000 -> 0.001 pu, rounded
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
					IF j = 4 THEN
						cp <= '1';
						j <= 0;
					ELSE
						j <= j + 1;
					END IF;
				END IF;
			END IF;
			b <= (b + 1) MOD 16;

			pa <= op(ir);                            -- PK: sample, square, keep
			pb <= op(ii);
			pt <= tr AND sp;
			sq <= UNSIGNED(RESIZE(pa * pa, 36) + RESIZE(pb * pb, 36));
			pt2 <= pt;
			IF pt2 = '1' AND sq > pk THEN
				pk <= sq;
			END IF;
			IF w > 0 AND w < 24 THEN
				w <= w + 1;
			END IF;
			IF w = 3 THEN                            -- the samples up to the copied step are in pk
				rad <= pk & "0000";
				rm <= (OTHERS => '0');
				root <= (OTHERS => '0');
			ELSIF w > 3 AND w < 24 THEN               -- one root bit per clock (w 4..23)
				e := rm(21 DOWNTO 0) & rad(39 DOWNTO 38);
				rad <= rad(37 DOWNTO 0) & "00";
				IF e >= root & "01" THEN
					rm <= e - (root & "01");
					root <= root(18 DOWNTO 0) & '1';
				ELSE
					rm <= e;
					root <= root(18 DOWNTO 0) & '0';
				END IF;
			END IF;
			rc <= (rc + 1) MOD nr;
			IF rc = 0 THEN
				due <= '1';
			END IF;
			IF cp = '1' AND cr = '1' THEN            -- the round of a column copy is done
				c1 <= (dig(dg), bad, str, hm, set, '1');
				IF sx < sxm THEN
					c1.lo <= sx;
				ELSE
					c1.lo <= sxm;
				END IF;
				cr <= '0';
			END IF;
			ce1 <= ce;
			IF ce = '1' AND ce1 = '0' THEN
				cm <= '1';
			END IF;
			IF wr = '1' THEN
				c2 <= c1;
			END IF;
			IF sv = '1' AND wr = '1' THEN            -- a column written with the save itself
				pv <= c1;
			ELSIF sv = '1' AND c2.ok = '1' THEN
				pv <= c2;
			END IF;
			IF sp = '1' OR load = '1' THEN            -- after a load: the start state, until the first edge
				lx <= x;
				lxm <= xmin;
				lsh <= shed;
				lt <= t;
				ltr <= tr;
			END IF;
			-- copy, then start a new round; a round that ends on this clock belongs to the old copy: drop it.
			-- A column copy is taken at the edge that ends the column and nothing else is copied until its
			-- round is done. While the model is held (fz) a refresh comes at once, from the inputs kept at
			-- the last step edge: some blocks have already written parts of the next step (shed at c = 12..18)
			IF cr = '0' AND ((cm = '1' AND sp = '1') OR (due = '1' AND (sp = '1' OR fz = '1'))) THEN
				cr <= cm AND sp;
				cp <= '0';
				IF sp = '1' THEN
					cm <= '0';
					sx <= x;
					sxm <= xmin;
					ssh <= shed;
					st <= t;
					str <= tr;
				ELSE
					sx <= lx;
					sxm <= lxm;
					ssh <= lsh;
					st <= lt;
					str <= ltr;
				END IF;
				due <= '0';
				j <= 0;
				b <= 0;
				w <= 1;
			END IF;
			IF load = '1' THEN                       -- the old peak is never shown after a load
				htr <= '0';
				pk <= (OTHERS => '0');
				pt <= '0';
				pt2 <= '0';
				str <= '0';
				cp <= '0';
				cm <= '0';
				cr <= '0';
				c2.ok <= '0';
				j <= 0;
				b <= 0;
			END IF;
		END IF;
	END PROCESS;

	db <= hb;
	dt <= htr;
	lo <= hm;
	dd <= dig(hd);
	rdy <= NOT (cm OR cr);
	g : FOR i IN 0 TO 3 GENERATE
		hex(i + 4) <= ERR(i) WHEN (pg = '0' AND hb(0) = '1') OR (pg = '1' AND hb(2) = '1')
			ELSE seg(hd(0)(i)) WHEN pg = '0' ELSE seg(hd(2)(i));
		hex(i) <= DASH WHEN htr = '0' ELSE ERR(i) WHEN (pg = '0' AND hb(1) = '1') OR (pg = '1' AND hb(3) = '1')
			ELSE seg(hd(1)(i)) WHEN pg = '0' ELSE seg(hd(3)(i));
	END GENERATE;
END a;
