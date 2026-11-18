LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE ieee.std_logic_textio.ALL;
USE std.textio.ALL;

-- Shared by the testbenches. hread only takes lengths that are a multiple of 4, so a value of any width
-- is read through the full hex digits and the low bits are kept.
-- The readers below cover the vector files: one window line (step number and the 18 Q(32,28) words in
-- front), one _sig line (21 node values, sign-extended to 36 bits) and the 81 config values.
PACKAGE tb_util IS
	TYPE row18 IS ARRAY (0 TO 17) OF SIGNED(31 DOWNTO 0);
	TYPE sigs IS ARRAY (0 TO 20) OF SIGNED(35 DOWNTO 0);
	TYPE cfgs IS ARRAY (0 TO 80) OF SIGNED(47 DOWNTO 0);
	PROCEDURE hrd (l : INOUT LINE; v : OUT STD_LOGIC_VECTOR);
	PROCEDURE rowread (l : INOUT LINE; k : OUT INTEGER; v : OUT row18);
	PROCEDURE sigread (l : INOUT LINE; v : OUT sigs);
	PROCEDURE cfgread (FILE f : TEXT; v : OUT cfgs);
END tb_util;

PACKAGE BODY tb_util IS
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
