#---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
#---------------------------------------------------------------------------------------------------
# Out-of-context implementation of one OpenCompact top level (called by lint/vivado_ooc.py).
#
# Arguments: <name> <top level file> <work directory> <result directory> <clock period in ns> <part>
#            <elaborate|implement> <repository root>
#
# The project holds Open Logic (library olo), the OpenCompact sources (library opencompact, in the order of
# compile_order.txt) and the top level, all VHDL-2008. Constraints: the clock of the top level and the scoped
# constraints of the Open Logic modules that OpenCompact uses (olo_base_ram_sdp; the other scoped constraints of Open
# Logic belong to clock crossings that OpenCompact does not contain). Before opt_design the run stops when a
# constraint did not apply (lint/vivado_check_constraints.tcl).
#---------------------------------------------------------------------------------------------------

lassign $argv name top work results period part mode root

set olo [file join $root open-logic]
file mkdir $results

create_project -force ooc_$name [file join $work prj] -part $part
set_property target_language VHDL [current_project]

# Open Logic: the areas base, axi and ft in the order of its compile_order.txt
set fh [open [file join $olo compile_order.txt] r]
set olo_files {}
foreach line [split [read $fh] "\n"] {
    set rel [string trim $line]
    if {$rel eq ""} { continue }
    set area [lindex [split $rel /] 1]
    if {$area in {base axi ft}} { lappend olo_files [file join $olo $rel] }
}
close $fh
add_files -norecurse $olo_files
set_property library olo [get_files $olo_files]

# OpenCompact in the order of compile_order.txt
set fh [open [file join $root compile_order.txt] r]
set ocp_files {}
foreach line [split [read $fh] "\n"] {
    set rel [string trim $line]
    if {$rel ne ""} { lappend ocp_files [file join $root $rel] }
}
close $fh
add_files -norecurse $ocp_files
set_property library opencompact [get_files $ocp_files]

add_files -norecurse $top
set_property file_type {VHDL 2008} [get_files -filter {FILE_TYPE == VHDL}]
set_property top ocp_synth_top [current_fileset]
update_compile_order -fileset sources_1

# Clock of the top level
set clock_xdc [file join $work ooc_clock.xdc]
set fh [open $clock_xdc w]
puts $fh "# Written by lint/vivado_ooc.tcl: core clock, [format %.1f [expr {1000.0 / $period}]] MHz"
puts $fh "create_clock -period $period -name clk \[get_ports ClkIn\]"
close $fh
add_files -fileset constrs_1 -norecurse $clock_xdc

# Scoped constraints of Open Logic, loaded as olo_base_constraints_amd.tcl does for this module
set ram_xdc [file join $olo src base tcl olo_base_ram_sdp.tcl]
read_xdc -quiet -ref olo_base_ram_sdp $ram_xdc -unmanaged
set_property used_in_synthesis false [get_files $ram_xdc]
set_property PROCESSING_ORDER LATE [get_files $ram_xdc]

if {$mode eq "elaborate"} {
    # RTL elaboration only: sources, generics, the top level and the clock constraint; no synthesis or implementation
    synth_design -rtl -rtl_skip_mlo -name rtl_1 -mode out_of_context
    if {[llength [get_clocks -quiet clk]] != 1} { error "vivado_ooc: the clock constraint of $name did not apply" }
    report_clocks -file [file join $results ${name}_rtl_clocks.rpt]
    set critical [get_msg_config -severity {CRITICAL WARNING} -count]
    if {$critical > 0} { error "vivado_ooc: $critical critical warnings in the elaboration of $name" }
    puts "vivado_ooc: $name elaborated, clock [get_property PERIOD [get_clocks clk]] ns"
    close_project
    exit 0
}

# Out-of-context synthesis from scratch, implementation up to routing
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property STEPS.OPT_DESIGN.TCL.PRE [file join $root lint vivado_check_constraints.tcl] [get_runs impl_1]

launch_runs synth_1
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "vivado_ooc: synthesis of $name failed" }
launch_runs impl_1 -to_step route_design
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "vivado_ooc: implementation of $name failed" }

open_run impl_1
report_timing_summary -max_paths 20 -file [file join $results ${name}_timing.rpt]
report_utilization -file [file join $results ${name}_util.rpt]
report_timing -setup -max_paths 20 -nworst 1 -sort_by slack -file [file join $results ${name}_paths.rpt]
report_design_analysis -logic_level_distribution -file [file join $results ${name}_levels.rpt]

# One summary line: setup and hold slack, failing endpoints, resources (the reports above are authoritative; an
# error here does not fail the run)
proc count {pattern} {
    return [llength [get_cells -hierarchical -quiet -filter "IS_PRIMITIVE && REF_NAME =~ $pattern"]]
}
if {[catch {
    set setup [lindex [get_timing_paths -setup -max_paths 1 -nworst 1] 0]
    set hold [lindex [get_timing_paths -hold -max_paths 1 -nworst 1] 0]
    set wns [expr {$setup eq "" ? "n/a" : [format %.3f [get_property SLACK $setup]]}]
    set whs [expr {$hold eq "" ? "n/a" : [format %.3f [get_property SLACK $hold]]}]
    set tns 0.0
    set failing 0
    foreach p [get_timing_paths -setup -max_paths 100000 -nworst 1 -slack_lesser_than 0 -quiet] {
        set tns [expr {$tns + [get_property SLACK $p]}]
        incr failing
    }
    set luts [llength [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE && PRIMITIVE_GROUP == CLB && PRIMITIVE_SUBGROUP == LUT}]]
    set ffs [llength [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE && PRIMITIVE_GROUP == REGISTER}]]
    set line [format "| %s | %s | %.3f | %d | %s | %d | %d | %d | %d | %d | %d |" $name $wns $tns $failing $whs $luts $ffs \
        [count RAMB36*] [count RAMB18*] [count URAM*] [count DSP*]]
    set fh [open [file join $results ${name}_summary.txt] w]
    puts $fh $line
    close $fh
    puts "vivado_ooc: $line"
} err]} {
    puts "vivado_ooc: no summary line for $name: $err"
}
close_project
