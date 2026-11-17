# Batch run of every testbench: vsim -c -do run_tb.do
# A failed compile or a FAILURE assertion ends vsim with exit code 1.
onerror {quit -code 1}
onbreak {quit -code 1}
vlib work
vcom -93 tb_util.vhd ../src/tick.vhd ../src/nco.vhd hrd_tb.vhd tick_tb.vhd nco_tb.vhd
vsim -c hrd_tb
run -all
quit -sim
foreach f [lsort [glob vectors/*_*.txt]] {
	if {[regexp {_(sig|config|start|windows)\.txt$} $f]} continue
	vsim -c -gfname=$f tick_tb
	run -all
	quit -sim
	vsim -c -gfname=[file rootname $f] nco_tb
	run -all
	quit -sim
}
quit -code 0
