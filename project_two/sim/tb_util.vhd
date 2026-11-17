LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.std_logic_textio.ALL;
USE std.textio.ALL;

-- Shared by the testbenches. hread only takes lengths that are a multiple of 4, so a value of any width
-- is read through the full hex digits and the low bits are kept.
PACKAGE tb_util IS
	PROCEDURE hrd (l : INOUT LINE; v : OUT STD_LOGIC_VECTOR);
END tb_util;

PACKAGE BODY tb_util IS
	PROCEDURE hrd (l : INOUT LINE; v : OUT STD_LOGIC_VECTOR) IS
		VARIABLE t : STD_LOGIC_VECTOR((v'LENGTH + 3) / 4 * 4 - 1 DOWNTO 0);
	BEGIN
		hread(l, t);
		v := t(v'LENGTH - 1 DOWNTO 0);
	END hrd;
END tb_util;
