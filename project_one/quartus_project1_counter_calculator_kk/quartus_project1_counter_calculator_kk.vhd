-- Project #1 Counter + Calculator (DE2)
-- SW0: 0=counter 1=calculator | Counter: KEY3 +1/+5  KEY2 +2/+10  KEY1 -1/-5  KEY0 reset  SW1 step
-- Calculator: A=SW17..14  B=SW13..10  SW2..1 op (00 + 01 - 10 * 11 /)  SW3 hex
ENTITY quartus_project1_counter_calculator_kk IS
PORT ( CLOCK_50 : IN  BIT;
       KEY, SW  : IN  BIT_VECTOR(3 DOWNTO 0);
       A, B     : IN  INTEGER RANGE 0 TO 15;
       HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7 : OUT BIT_VECTOR(6 DOWNTO 0);
       LEDR : OUT INTEGER RANGE 0 TO 2**18 - 1;  LEDG : OUT INTEGER RANGE 0 TO 2**9 - 1 );
END quartus_project1_counter_calculator_kk;

ARCHITECTURE a OF quartus_project1_counter_calculator_kk IS
  SIGNAL k1, k2, k3, p : BIT_VECTOR(3 DOWNTO 0);
  SIGNAL count      : INTEGER RANGE 0 TO 9999;
  SIGNAL t          : INTEGER RANGE 0 TO 16666666;   -- 50 MHz / 3 Hz
  SIGNAL step, base : INTEGER RANGE 1 TO 16;         -- counter step 1/5, display base 10/16
  SIGNAL res        : INTEGER RANGE -15 TO 225;      -- A op B (worst case 0-15, 15*15)
  SIGNAL ie, dv      : BOOLEAN;                       -- input error, divide (B = 0 checked where used)
  CONSTANT SEG_OFF : BIT_VECTOR(6 DOWNTO 0) := "1111111";
  CONSTANT SEG_E   : BIT_VECTOR(6 DOWNTO 0) := "0000110";
  CONSTANT SEG_R   : BIT_VECTOR(6 DOWNTO 0) := "0101111";
  TYPE rom IS ARRAY (0 TO 15) OF BIT_VECTOR(6 DOWNTO 0);   -- 7-seg ROM, "gfedcba", 0 = on
  CONSTANT SEG7 : rom := (                                 -- row 1: 0~7, row 2: 8 9 A b C d E F
    "1000000", "1111001", "0100100", "0110000", "0011001", "0010010", "0000010", "1111000",
    "0000000", "0010000", "0001000", "0000011", "1000110", "0100001", "0000110", "0001110");

  FUNCTION digit (n, w, radix : INTEGER) RETURN BIT_VECTOR IS   -- 7-seg of digit at weight w
  BEGIN
    IF w > 1 AND n < w THEN RETURN SEG_OFF; END IF;          -- leading zero off
    RETURN SEG7((n / w) MOD radix);
  END digit;

BEGIN
  p <= k3 AND NOT k2;                                  -- 1-clock pulse when pressed
  WITH SW(1) SELECT step <= 5 WHEN '1', 1 WHEN OTHERS;
  WITH SW(3) SELECT base <= 16 WHEN '1', 10 WHEN OTHERS;
  WITH SW(2 DOWNTO 1) SELECT                           -- "11" (divide) is handled by dv
    res <= A + B WHEN "00", A - B WHEN "01", A * B WHEN OTHERS;
  ie <= A > 9 OR B > 9;  dv <= SW(2 DOWNTO 1) = "11";

  PROCESS (CLOCK_50)                                   -- counter (sequential)
    VARIABLE n : INTEGER RANGE -5 TO 10009;
  BEGIN
    IF CLOCK_50 = '1' AND CLOCK_50'EVENT THEN
      k1 <= KEY;  k2 <= k1;  k3 <= k2;
      IF SW(0) = '1' OR p(0) = '1' THEN n := 0;        -- reset / calculator mode
      ELSIF p(3) = '1' THEN n := count + step;
      ELSIF p(2) = '1' THEN n := count + 2 * step;
      ELSIF p(1) = '1' THEN n := count - step;
      ELSE  n := count; END IF;
      IF n > 9999 THEN n := n - 10000; ELSIF n < 0 THEN n := n + 10000; END IF;  -- MOD-10000 wrap
      count <= n;
      IF t = 16666666 THEN t <= 0; ELSE t <= t + 1; END IF;
    END IF;
  END PROCESS;

  -- LED: count in binary; 777 = jackpot (red half / green half of t); LEDG0 = hex mode
  LEDR <= count WHEN count /= 777 ELSE 2**18 - 1 WHEN t < 8333333 ELSE 0;
  LEDG <= 1 WHEN SW(0) = '1' AND SW(3) = '1' ELSE 2**9 - 1 WHEN count = 777 AND t >= 8333333 ELSE 0;

  -- display: counter when SW0 = 0; calculator priority  input error > divide by 0 > divide > + - *
  HEX7 <= SEG_OFF;  HEX5 <= SEG_OFF;
  HEX6 <= SEG_OFF WHEN SW(0) = '0' ELSE SEG_E WHEN A > 9 ELSE digit(A, 1, 10);
  HEX4 <= SEG_OFF WHEN SW(0) = '0' ELSE SEG_E WHEN B > 9 ELSE digit(B, 1, 10);
  HEX3 <= digit(count, 1000, 10) WHEN SW(0) = '0' ELSE SEG_OFF WHEN ie
          ELSE SEG_E WHEN dv AND B = 0 ELSE digit(A / B, 1, 10) WHEN dv ELSE SEG_OFF;   -- E / quotient
  HEX2 <= digit(count, 100, 10) WHEN SW(0) = '0' ELSE SEG_R WHEN dv AND B = 0 AND NOT ie ELSE SEG_OFF;
  HEX1 <= digit(count, 10, 10) WHEN SW(0) = '0' ELSE SEG_OFF WHEN ie ELSE SEG_R WHEN dv
          ELSE "0111111" WHEN res < 0 ELSE digit(ABS res, base, base);   -- r / minus
  HEX0 <= digit(count, 1, 10) WHEN SW(0) = '0' ELSE SEG_E WHEN ie ELSE SEG_OFF WHEN dv AND B = 0
          ELSE digit(A MOD B, 1, 10) WHEN dv ELSE digit(ABS res, 1, base);   -- remainder
END a;