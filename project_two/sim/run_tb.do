# Batch run of every testbench: vsim -c -do run_tb.do
# A failed compile or a FAILURE assertion ends vsim with exit code 1.
onerror {quit -code 1}
onbreak {quit -code 1}
vlib work
vcom -93 ../src/gfm_pkg.vhd tb_util.vhd ../src/tick.vhd ../src/nco.vhd ../src/plant_slow.vhd ../src/plant_fast.vhd
vcom -93 ../src/meas.vhd ../src/vctrl.vhd ../src/limiter.vhd ../src/cctrl.vhd ../src/controller.vhd ../src/pwm.vhd
vcom -93 ../src/core.vhd
vcom -93 ../src/scen.vhd ../src/run.vhd ../src/disp.vhd ../src/lcd.vhd ../src/vga.vhd ../src/rec.vhd ../src/scope.vhd ../src/text.vhd
vcom -93 ../src/screen.vhd ../src/board.vhd scen_tb.vhd disp_tb.vhd lcd_tb.vhd vga_tb.vhd rec_tb.vhd scope_tb.vhd
vcom -93 screen_tb.vhd text_tb.vhd board_tb.vhd run_tb.vhd keep_tb.vhd bank_tb.vhd prev_tb.vhd
vcom -93 hrd_tb.vhd tick_tb.vhd nco_tb.vhd plant_slow_tb.vhd plant_slow_edge_tb.vhd plant_fast_tb.vhd plant_fast_edge_tb.vhd
vcom -93 meas_tb.vhd vctrl_tb.vhd limiter_tb.vhd limiter_edge_tb.vhd cctrl_tb.vhd controller_tb.vhd core_tb.vhd
vcom -93 pwm_tb.vhd
foreach t {hrd_tb plant_slow_edge_tb plant_fast_edge_tb limiter_edge_tb scen_tb disp_tb lcd_tb vga_tb rec_tb scope_tb screen_tb text_tb board_tb run_tb keep_tb
		bank_tb prev_tb} {
	vsim -c $t
	run -all
	quit -sim
}
foreach f [lsort [glob vectors/*_*.txt]] {
	if {[regexp {_(sig|config|start|windows)\.txt$} $f]} continue
	set r [file rootname $f]
	regsub {^(vectors/[a-z]+_[a-z]+)_.*$} $r {\1_config.txt} cfg
	if {[regexp {^vectors/[a-z]+a_} $f]} {
		# trip A cases: only the scenario input differs, so the closed loop is the check
		vsim -c -gfname=$r -gcname=$cfg core_tb
		run -all
		quit -sim
		continue
	}
	vsim -c -gfname=$f tick_tb
	run -all
	quit -sim
	vsim -c -gfname=$r nco_tb
	run -all
	quit -sim
	foreach t {plant_slow_tb plant_fast_tb meas_tb vctrl_tb limiter_tb cctrl_tb controller_tb core_tb} {
		vsim -c -gfname=$r -gcname=$cfg $t
		run -all
		quit -sim
	}
}
# PWM block alone, tick by tick, and the whole loop with the PWM model, on every window; then pauses
# and forced end duties
foreach f [lsort [glob vectors/pwm/*_sig.txt]] {
	set r [string range $f 0 end-8]
	set v [expr {[string match *_40_* $r] ? "true" : "false"}]
	regsub {^vectors/pwm/([a-z]+_[a-z]+)_.*$} $r {vectors/\1_config.txt} cfg
	vsim -c -gfname=$r -gvdc40=$v pwm_tb
	run -all
	quit -sim
	vsim -c -gfname=$r -gcname=$cfg -gpwm=true -gvdc40=$v core_tb
	run -all
	quit -sim
}
foreach g {{spec_fb_24_imax_step -gpause=true} {held_fb_40_start -gvdc40=true -gpause=true}
		{held_sat_24_clip -gforce=true -gpause=true}} {
	eval vsim -c -gfname=vectors/pwm/[lindex $g 0] [lrange $g 1 end] pwm_tb
	run -all
	quit -sim
}
# the model held at random clocks (go low for 1..16 clocks) runs bit for bit the same, average and PWM
vsim -c -ghold=true core_tb
run -all
quit -sim
vsim -c -gfname=vectors/pwm/held_sat_24_trip -gpwm=true -ghold=true core_tb
run -all
quit -sim
# a reset after a PWM run at the other vdc leaves nothing behind
vsim -c -gfname=vectors/pwm/held_fb_24_start -gcname=vectors/held_fb_config.txt -gpwm=true -gpre=3000 core_tb
run -all
quit -sim
quit -code 0
