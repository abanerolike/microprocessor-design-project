# Batch run of every testbench: vsim -c -do run_tb.do
# A failed compile or a FAILURE assertion ends vsim with exit code 1.
onerror {quit -code 1}
onbreak {quit -code 1}
vlib work
vcom -93 tb_util.vhd ../src/gfm_pkg.vhd ../src/tick.vhd ../src/nco.vhd ../src/plant_slow.vhd
vcom -93 hrd_tb.vhd tick_tb.vhd nco_tb.vhd plant_slow_tb.vhd plant_slow_edge_tb.vhd
foreach t {hrd_tb plant_slow_edge_tb} {
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
	vsim -c -gfname=$r -gcname=$cfg plant_slow_tb
	run -all
	quit -sim
}
quit -code 0
