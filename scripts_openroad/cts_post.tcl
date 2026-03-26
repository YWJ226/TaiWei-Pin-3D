utl::set_metrics_stage "cts__{}"
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

load_design 4_cts.def 4_cts.sdc "Starting POST CTS..."

source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl

set cts_layer "bottom"
set fix_layer "upper"
if {[info exists ::env(CTS_LAYER)]} {
  set cts_layer $::env(CTS_LAYER)
  if { $cts_layer == "bottom" } {
    set fix_layer "upper"
  } else {
    set fix_layer "bottom"
  }
  puts "CTS LAYER: $cts_layer"
}

# mark_insts_by_master "*${cts_layer}*" FIRM
# puts "Marked ${cts_layer} instances as FIRM"

apply_tier_policy $fix_layer -cts_safe 1 -fixlib 1

utl::push_metrics_stage "cts__{}__pre_repair_timing"
estimate_parasitics -placement
utl::pop_metrics_stage

set_placement_padding -global \
  -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
  -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

# CTS leaves a long wire from the pad to the clock tree root.
log_cmd repair_clock_nets

# place clock buffers
log_cmd detailed_placement 

estimate_parasitics -placement

if { ![info exists ::env(SKIP_CTS_REPAIR_TIMING)] } {
  set ::env(SKIP_CTS_REPAIR_TIMING) 0
}
if { $::env(SKIP_CTS_REPAIR_TIMING) } {

  repair_timing_helper

  set result [catch { detailed_placement } msg]
  if { $result != 0 } {
    save_progress 4_1_error
    puts "Detailed placement failed in CTS: $msg"
    exit $result
  }

  check_placement -verbose
}

# mark_insts_by_master "*${cts_layer}*" PLACED
# puts "Marked ${cts_layer} instances as PLACED"
source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 4 "cts" false false

write_def $::env(RESULTS_DIR)/4_cts.def
write_verilog $::env(RESULTS_DIR)/4_cts.v
write_sdc $::env(RESULTS_DIR)/4_cts.sdc
save_image -resolution 0.1 $::env(LOG_DIR)/4_cts_post.webp 

exit