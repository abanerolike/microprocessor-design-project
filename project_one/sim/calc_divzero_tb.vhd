-- Calculator divide-by-zero check: B changes to 0 while the divide mode is on, the mode changes
-- into divide while B = 0, and both change on the same delta. The divider and the remainder must
-- never be evaluated with B = 0 (the simulator stops with a divide-by-zero error if they are).
-- Run in this folder: vlib work; vcom ../quartus_project1_counter_calculator_kk/quartus_project1_counter_calculator_kk.vhd calc_divzero_tb.vhd; vsim -c calc_divzero_tb -do "run -all; quit"
ENTITY calc_divzero_tb IS END calc_divzero_tb;
ARCHITECTURE t OF calc_divzero_tb IS
  SIGNAL clk : BIT := '0';
  SIGNAL KEY : BIT_VECTOR(3 DOWNTO 0) := "1111";
  SIGNAL SW : BIT_VECTOR(3 DOWNTO 0) := "0111";   -- calculator, divide
  SIGNAL A, B : INTEGER RANGE 0 TO 15 := 7;
  SIGNAL h0,h1,h2,h3,h4,h5,h6,h7 : BIT_VECTOR(6 DOWNTO 0);
  SIGNAL lr : INTEGER RANGE 0 TO 2**18-1; SIGNAL lg : INTEGER RANGE 0 TO 2**9-1;
BEGIN
  dut : ENTITY work.quartus_project1_counter_calculator_kk PORT MAP (clk, KEY, SW, A, B, h0,h1,h2,h3,h4,h5,h6,h7, lr, lg);
  PROCESS BEGIN
    B <= 2; WAIT FOR 100 ns;
    ASSERT h3 = "0110000" REPORT "7/2 quotient" SEVERITY FAILURE;   -- 3
    B <= 0; WAIT FOR 100 ns;                                        -- divide mode, B 2 -> 0
    ASSERT h3 = "0000110" AND h2 = "0101111" AND h0 = "1111111" REPORT "div by 0 display" SEVERITY FAILURE;
    SW <= "0001"; WAIT FOR 100 ns;  B <= 0;                         -- add mode with B = 0
    SW <= "0111"; WAIT FOR 100 ns;                                  -- switch into divide with B = 0
    ASSERT h3 = "0000110" REPORT "switch to div with B=0" SEVERITY FAILURE;
    B <= 3; SW <= "0001"; WAIT FOR 100 ns; B <= 0; SW <= "0111"; WAIT FOR 100 ns;  -- both change together
    ASSERT h3 = "0000110" REPORT "simultaneous change" SEVERITY FAILURE;
    REPORT "calc_divzero_tb PASS"; WAIT;
  END PROCESS;
END t;
