# FPGA Design Projects on the Altera DE2

This repo has our VHDL designs for the Altera DE2 board (Cyclone II EP2C35F672C6). We used Quartus II 13.0sp1 for synthesis and ModelSim-Altera for simulation. The whole design runs on the 50 MHz board clock, and slower timing is made with clock enables.

## Project 1: Counter and one-digit calculator

Both functions are in one bitstream. SW0 selects the counter or the calculator, and the board keeps working after the USB cable is removed.

### Counter

- KEY3, KEY2 and KEY1 add 1, add 2 and subtract 1. With SW1 on, the steps are 5, 10 and 5. KEY0 resets the count.
- The count wraps at both ends (9999 + 1 = 0, 0 - 1 = 9999). We chose this because a stop at 0 makes 3 - 5 + 5 give 5, not 3.
- LEDR13-0 show the count in binary. At 777, all 27 LEDs blink at 3 Hz.

### Calculator

- A and B come from SW17-14 and SW13-10. SW2-1 select +, -, x or /.
- An input over 9 shows `E`, and division by zero shows `Err`.
- Division shows the remainder too (`3 r1`). SW3 changes the result to hex.

| Item | Result |
|---|---|
| Source | 1 file, 96 lines |
| Logic elements | 2,078 |
| Registers | 77 |
| Pins | 100 |
| Board tests | 39 counter cases, 19 calculator cases |

Our first counter used `mod 10000` and only reached 43.4 MHz. Quartus built the modulo as a divider in the clocked path. After we changed it to a range check, Fmax went up to 113.0 MHz.

## Project 2: Real-time grid-forming inverter emulator (in progress)

This part runs two models at different rates. A three-phase inverter model updates every 1 us, and a grid frequency model updates every 1.024 ms. We want to see how much inertia an inverter can really give the grid when its current is limited.

## Project 3: Project 2 split across two boards (planned)

This folder is only a skeleton for now. The plan is to run the controller on one DE2 and the inverter filter and grid on a second DE2. The target is a data exchange over the GPIO header every 1 us. We will start from the averaged model of Project 2 and check the split version bit for bit against a one-board model with the same delay.

## Layout

```
project_one/quartus_project1_counter_calculator_kk/   VHDL, pin and timing files
project_two/                                          in progress
project_three/quartus/ctrl_board/, plant_board/       one Quartus project per board, no sources yet
```

## Building

Open the `.qpf` file in Quartus II 13.0sp1 and run a full compile. Keep unused pins set to "As input tri-stated". Program the board over JTAG with the RUN/PROG switch on RUN.

Project 3 has no source files yet, so its two Quartus projects do not compile.
