-- Project #1 Counter + Calculator (DE2)
-- SW0: 0=counter 1=calculator | Counter: KEY3 +1/+5  KEY2 +2/+10  KEY1 -1/-5  KEY0 reset  SW1 step
-- Calculator: A=SW17..14  B=SW13..10  SW2..1 op (00 + 01 - 10 * 11 /)  SW3 hex
ENTITY quartus_project1_counter_calculator_kk IS
PORT ( CLOCK_50                   : IN  BIT;
       KEY                        : IN  BIT_VECTOR(3 DOWNTO 0);
       SW                         : IN  BIT_VECTOR(3 DOWNTO 0);
       A, B                       : IN  INTEGER RANGE 0 TO 15;
       HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7 : OUT BIT_VECTOR(6 DOWNTO 0);
       LEDR                       : OUT INTEGER RANGE 0 TO 262143;   -- 18 bit
       LEDG                       : OUT INTEGER RANGE 0 TO 511 );    -- 9 bit
END quartus_project1_counter_calculator_kk;

ARCHITECTURE a OF quartus_project1_counter_calculator_kk IS
  SIGNAL k1, k2, k3 : BIT_VECTOR(3 DOWNTO 0);
  SIGNAL count      : INTEGER RANGE 0 TO 9999;
  SIGNAL t          : INTEGER RANGE 0 TO 16666666;   -- 50 MHz / 3 Hz
  CONSTANT SEG_OFF   : BIT_VECTOR(6 DOWNTO 0) := "1111111";
  CONSTANT SEG_MINUS : BIT_VECTOR(6 DOWNTO 0) := "0111111";
  CONSTANT SEG_E     : BIT_VECTOR(6 DOWNTO 0) := "0000110";
  CONSTANT SEG_R     : BIT_VECTOR(6 DOWNTO 0) := "0101111";

  FUNCTION digit (n, w, b : INTEGER) RETURN BIT_VECTOR IS   -- 7-seg of digit at weight w, base b
  BEGIN
    IF w > 1 AND n < w THEN RETURN SEG_OFF; END IF;          -- leading zero off
    CASE (n / w) MOD b IS
      WHEN 0  => RETURN "1000000";  WHEN 1  => RETURN "1111001";
      WHEN 2  => RETURN "0100100";  WHEN 3  => RETURN "0110000";
      WHEN 4  => RETURN "0011001";  WHEN 5  => RETURN "0010010";
      WHEN 6  => RETURN "0000010";  WHEN 7  => RETURN "1111000";
      WHEN 8  => RETURN "0000000";  WHEN 9  => RETURN "0010000";
      WHEN 10 => RETURN "0001000";  WHEN 11 => RETURN "0000011";   -- A b
      WHEN 12 => RETURN "1000110";  WHEN 13 => RETURN "0100001";   -- C d
      WHEN 14 => RETURN SEG_E;      WHEN OTHERS => RETURN "0001110"; -- E F
    END CASE;
  END digit;

BEGIN
  PROCESS (CLOCK_50)                                   -- counter (sequential)
    VARIABLE p    : BIT_VECTOR(3 DOWNTO 0);
    VARIABLE step : INTEGER RANGE 1 TO 5;
    VARIABLE n    : INTEGER RANGE -5 TO 10009;
  BEGIN
    IF CLOCK_50 = '1' AND CLOCK_50'EVENT THEN
      k1 <= KEY;  k2 <= k1;  k3 <= k2;
      p := k3 AND NOT k2;                              -- 1-clock pulse when pressed
      IF SW(1) = '1' THEN step := 5; ELSE step := 1; END IF;

      IF SW(0) = '1' OR p(0) = '1' THEN n := 0;        -- reset / calculator mode
      ELSIF p(3) = '1' THEN n := count + step;
      ELSIF p(2) = '1' THEN n := count + 2 * step;
      ELSIF p(1) = '1' THEN n := count - step;
      ELSE  n := count; END IF;
      IF n > 9999 THEN n := n - 10000; ELSIF n < 0 THEN n := n + 10000; END IF;  -- MOD-10000 wrap
      count <= n;

      IF t = 16666666 THEN t <= 0; ELSE t <= t + 1; END IF;
      IF count /= 777 THEN LEDR <= count;  LEDG <= 0;   -- binary
      ELSIF t < 8333333 THEN LEDR <= 262143; LEDG <= 0;  -- jackpot: red half
      ELSE LEDR <= 0; LEDG <= 511;                       --          green half
      END IF;
      IF SW(0) = '1' AND SW(3) = '1' THEN LEDG <= 1; END IF;   -- hex mode indicator
    END IF;
  END PROCESS;

  PROCESS (SW, A, B, count)                            -- display mux + calculator (combinational)
    VARIABLE base : INTEGER RANGE 10 TO 16;
    VARIABLE res  : INTEGER RANGE -15 TO 225;
  BEGIN
    HEX0 <= SEG_OFF;  HEX1 <= SEG_OFF;  HEX2 <= SEG_OFF;  HEX3 <= SEG_OFF;   -- default: all off
    HEX4 <= SEG_OFF;  HEX5 <= SEG_OFF;  HEX6 <= SEG_OFF;  HEX7 <= SEG_OFF;
    IF SW(0) = '0' THEN                                -- counter
      HEX0 <= digit(count, 1, 10);    HEX1 <= digit(count, 10, 10);
      HEX2 <= digit(count, 100, 10);  HEX3 <= digit(count, 1000, 10);
    ELSE                                               -- calculator
      HEX6 <= digit(A, 1, 10);  HEX4 <= digit(B, 1, 10);
      IF A > 9 THEN HEX6 <= SEG_E; END IF;
      IF B > 9 THEN HEX4 <= SEG_E; END IF;
      IF SW(3) = '1' THEN base := 16; ELSE base := 10; END IF;
      CASE SW(2 DOWNTO 1) IS
        WHEN "00"   => res := A + B;
        WHEN "01"   => res := A - B;
        WHEN OTHERS => res := A * B;                   -- not used for "11"
      END CASE;
      IF A > 9 OR B > 9 THEN HEX0 <= SEG_E;            -- 1. input error   "   E"
      ELSIF SW(2 DOWNTO 1) = "11" AND B = 0 THEN       -- 2. divide by 0   "Err "
        HEX3 <= SEG_E;  HEX2 <= SEG_R;  HEX1 <= SEG_R;
      ELSIF SW(2 DOWNTO 1) = "11" THEN                 -- 3. division      "q r#"
        HEX3 <= digit(A / B, 1, 10);  HEX1 <= SEG_R;  HEX0 <= digit(A MOD B, 1, 10);
      ELSE                                             -- 4. + - *         "  -4", " 51"
        HEX1 <= digit(ABS res, base, base);  HEX0 <= digit(ABS res, 1, base);
        IF res < 0 THEN HEX1 <= SEG_MINUS; END IF;     -- |res| <= 9, so sign is always on HEX1
      END IF;
    END IF;
  END PROCESS;
END a;