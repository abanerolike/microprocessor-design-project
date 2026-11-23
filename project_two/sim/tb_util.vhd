LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE ieee.std_logic_textio.ALL;
USE std.textio.ALL;
USE work.gfm_pkg.ALL;

-- Shared by the testbenches. hread only takes lengths that are a multiple of 4, so a value of any width
-- is read through the full hex digits and the low bits are kept.
-- The readers below cover the vector files: one window line (step number and the 18 Q(32,28) words in
-- front), one _sig line (21 node values, sign-extended to 36 bits) and the 81 config values; and for the
-- PWM vectors one window line (k, i1, the 15 PWM words) and one _sig line.
PACKAGE tb_util IS
	TYPE row18 IS ARRAY (0 TO 17) OF SIGNED(31 DOWNTO 0);
	TYPE sigs IS ARRAY (0 TO 20) OF SIGNED(35 DOWNTO 0);
	TYPE cfgs IS ARRAY (0 TO 80) OF SIGNED(47 DOWNTO 0);
	TYPE pwords IS RECORD
		k, flag : INTEGER;
		i1r, i1i : SIGNED(31 DOWNTO 0);
		da, dp : duties;
		cm : STD_LOGIC_VECTOR(0 TO 2);
		dc : deads;
		ur, ui : SIGNED(33 DOWNTO 0);
	END RECORD;
	TYPE swords IS RECORD
		v1r, v1i, ur, ui : SIGNED(33 DOWNTO 0);
		ph : UNSIGNED(39 DOWNTO 0);
		ng : STD_LOGIC_VECTOR(0 TO 2);
		n : duties;
		dp : duties;
		ck, sk : SIGNED(17 DOWNTO 0);
	END RECORD;
	PROCEDURE hrd (l : INOUT LINE; v : OUT STD_LOGIC_VECTOR);
	PROCEDURE prow (l : INOUT LINE; r : OUT pwords);
	PROCEDURE psig (l : INOUT LINE; s : OUT swords);
	PROCEDURE rowread (l : INOUT LINE; k : OUT INTEGER; v : OUT row18);
	PROCEDURE sigread (l : INOUT LINE; v : OUT sigs);
	PROCEDURE cfgread (FILE f : TEXT; v : OUT cfgs);
END tb_util;

PACKAGE BODY tb_util IS
	PROCEDURE prow (l : INOUT LINE; r : OUT pwords) IS
		VARIABLE w : STD_LOGIC_VECTOR(39 DOWNTO 0);
		VARIABLE w34 : STD_LOGIC_VECTOR(33 DOWNTO 0);
		TYPE widths IS ARRAY (0 TO 37) OF INTEGER;
		CONSTANT wd : widths := (32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 40, 40,
			32, 32, 28, 32, 16, 16, 16, 16, 16, 16, 16, 4, 4, 4, 4, 4, 4, 4);
	BEGIN
		read(l, r.k);
		FOR i IN wd'RANGE LOOP                         -- state and run-internal words; only i1 is kept
			hrd(l, w(wd(i) - 1 DOWNTO 0));
			IF i = 0 THEN
				r.i1r := SIGNED(w(31 DOWNTO 0));
			ELSIF i = 1 THEN
				r.i1i := SIGNED(w(31 DOWNTO 0));
			END IF;
		END LOOP;
		hrd(l, w(3 DOWNTO 0));
		r.flag := TO_INTEGER(UNSIGNED(w(3 DOWNTO 0)));
		FOR x IN 0 TO 2 LOOP
			hrd(l, w(15 DOWNTO 0));
			r.da(x) := TO_INTEGER(UNSIGNED(w(15 DOWNTO 0)));
		END LOOP;
		FOR x IN 0 TO 2 LOOP
			hrd(l, w(15 DOWNTO 0));
			r.dp(x) := TO_INTEGER(UNSIGNED(w(15 DOWNTO 0)));
		END LOOP;
		FOR x IN 0 TO 2 LOOP
			hrd(l, w(3 DOWNTO 0));
			r.cm(x) := w(0);
		END LOOP;
		FOR x IN 0 TO 2 LOOP
			hrd(l, w(7 DOWNTO 0));
			r.dc(x) := TO_INTEGER(UNSIGNED(w(7 DOWNTO 0)));
		END LOOP;
		hrd(l, w34);
		r.ur := SIGNED(w34);
		hrd(l, w34);
		r.ui := SIGNED(w34);
	END prow;

	PROCEDURE psig (l : INOUT LINE; s : OUT swords) IS
		VARIABLE w : STD_LOGIC_VECTOR(39 DOWNTO 0);
	BEGIN
		hrd(l, w(33 DOWNTO 0));
		s.v1r := SIGNED(w(33 DOWNTO 0));
		hrd(l, w(33 DOWNTO 0));
		s.v1i := SIGNED(w(33 DOWNTO 0));
		hrd(l, w);
		s.ph := UNSIGNED(w);
		hrd(l, w(3 DOWNTO 0));
		s.ng := (w(0), w(1), w(2));
		FOR x IN 0 TO 2 LOOP
			hrd(l, w(7 DOWNTO 0));
			s.n(x) := TO_INTEGER(UNSIGNED(w(7 DOWNTO 0)));
		END LOOP;
		FOR x IN 0 TO 2 LOOP
			hrd(l, w(15 DOWNTO 0));
			s.dp(x) := TO_INTEGER(UNSIGNED(w(15 DOWNTO 0)));
		END LOOP;
		hrd(l, w(33 DOWNTO 0));
		s.ur := SIGNED(w(33 DOWNTO 0));
		hrd(l, w(33 DOWNTO 0));
		s.ui := SIGNED(w(33 DOWNTO 0));
		hrd(l, w(17 DOWNTO 0));
		s.ck := SIGNED(w(17 DOWNTO 0));
		hrd(l, w(17 DOWNTO 0));
		s.sk := SIGNED(w(17 DOWNTO 0));
	END psig;
	PROCEDURE hrd (l : INOUT LINE; v : OUT STD_LOGIC_VECTOR) IS
		VARIABLE t : STD_LOGIC_VECTOR((v'LENGTH + 3) / 4 * 4 - 1 DOWNTO 0);
	BEGIN
		hread(l, t);
		v := t(v'LENGTH - 1 DOWNTO 0);
	END hrd;

	-- i1, vc, i2, i1f, vcf, i2f (re, im), uv, ui (re, im), pf, qf
	PROCEDURE rowread (l : INOUT LINE; k : OUT INTEGER; v : OUT row18) IS
		VARIABLE w : STD_LOGIC_VECTOR(31 DOWNTO 0);
	BEGIN
		read(l, k);
		FOR i IN v'RANGE LOOP
			hrd(l, w);
			v(i) := SIGNED(w);
		END LOOP;
	END rowread;

	-- v1 (re, im), il (re, im), lim, exc, dm, inc, incg, pg, th cos, sin, thg cos, sin,
	-- ir (re, im), wm1, xw (re, im), uv1 (re, im)
	PROCEDURE sigread (l : INOUT LINE; v : OUT sigs) IS
		TYPE widths IS ARRAY (0 TO 20) OF INTEGER;
		CONSTANT wd : widths := (34, 34, 32, 32, 2, 33, 18, 26, 25, 18, 18, 18, 18, 18, 32, 32, 27, 31, 31, 24, 24);
		VARIABLE t : STD_LOGIC_VECTOR(35 DOWNTO 0);
	BEGIN
		FOR i IN v'RANGE LOOP
			hrd(l, t(wd(i) - 1 DOWNTO 0));
			v(i) := RESIZE(SIGNED(t(wd(i) - 1 DOWNTO 0)), 36);
		END LOOP;
	END sigread;

	PROCEDURE cfgread (FILE f : TEXT; v : OUT cfgs) IS
		VARIABLE l : LINE;
		VARIABLE w : STD_LOGIC_VECTOR(47 DOWNTO 0);
	BEGIN
		FOR i IN v'RANGE LOOP
			readline(f, l);
			hrd(l, w);
			v(i) := SIGNED(w);
		END LOOP;
	END cfgread;
END tb_util;
