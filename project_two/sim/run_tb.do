# Batch run of every testbench: vsim -c -do run_tb.do
# A failed compile or a FAILURE assertion ends vsim with exit code 1.
onerror {quit -code 1}
onbreak {quit -code 1}
vlib work
vcom -93 tb_util.vhd ../src/gfm_pkg.vhd ../src/tick.vhd ../src/nco.vhd ../src/plant_slow.vhd ../src/plant_fast.vhd
vcom -93 ../src/meas.vhd ../src/vctrl.vhd ../src/limiter.vhd ../src/cctrl.vhd ../src/controller.vhd ../src/core.vhd
vcom -93 hrd_tb.vhd tick_tb.vhd nco_tb.vhd plant_slow_tb.vhd plant_slow_edge_tb.vhd plant_fast_tb.vhd plant_fast_edge_tb.vhd
vcom -93 meas_tb.vhd vctrl_tb.vhd limiter_tb.vhd limiter_edge_tb.vhd cctrl_tb.vhd controller_tb.vhd core_tb.vhd
foreach t {hrd_tb plant_slow_edge_tb plant_fast_edge_tb limiter_edge_tb} {
	vsim -c $t
	run -all
	quit -sim
}
foreach f [lsort [glob vectors/*_*.txt]] {
	if {[regexp {_(sig|config|start|windows)\.txt$} $f]} continue
	set r [file rootname $f]
	regsub {^(vectors/[a-z]+_[a-z]+)_.*$} $r {\1_config.txt} cfg
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
quit -code 0
