# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# place_common.tcl — Stable pre-GR/pre-legal setup for Innovus placement
# Dependencies: utils.tcl / lib_setup.tcl / design_setup.tcl / mmmc_setup.tcl must be sourced.
# Environment Variables (Optional):
#   MAX_ROUTING_LAYER / MIN_ROUTING_LAYER : Constrain routing layers
# ==========================================
# Ensure namespace exists
if {![namespace exists pc]} {
  namespace eval pc {
    namespace export common_setup setup_basic run_place run_place_step run_loop_opt_step
  }
}

proc pc::_env_or {name default} {
  if {[info exists ::env($name)]} { return $::env($name) }
  return $default
}

proc pc::setup_basic {} {
  # --- Routing Layer Constraints (if set) ---
  if {[info exists ::env(MAX_ROUTING_LAYER)]} { setDesignMode -topRoutingLayer    $::env(MAX_ROUTING_LAYER) } 
  if {[info exists ::env(MIN_ROUTING_LAYER)]} { setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER) } 

  # --- Legalization and Filler ---
  setPlaceMode -place_detail_legalization_inst_gap 1
  setFillerMode -fitGap true
}

# Single-step placement/optimization stage.
proc pc::run_place_step {{prefix "prects"}} {
  puts "INFO\[pc\]: place_opt_design (integrated preCTS opt), stage=$prefix"
  # Report directory/prefix might be defined in your design script; provide a compatible fallback
  set reports_dir [expr {[info exists ::REPORTS_DIR] ? $::REPORTS_DIR : "./reports"}]
  file mkdir $reports_dir
  catch { place_opt_design -out_dir $reports_dir -prefix $prefix } msg
  if {[info exists msg] && $msg ne ""} { puts "INFO\[pc\]: $msg" }
  catch { checkPlace }
}

# Outer-loop incremental preCTS optimization stage.
proc pc::run_loop_opt_step {{prefix "loop_prects"}} {
  puts "INFO\[pc\]: loop incremental preCTS optimization, stage=$prefix"
  set reports_dir [expr {[info exists ::REPORTS_DIR] ? $::REPORTS_DIR : "./reports"}]
  file mkdir $reports_dir
  catch { optDesign -preCTS -incr -outDir $reports_dir -prefix $prefix } msg
  if {[info exists msg] && $msg ne ""} { puts "INFO\[pc\]: $msg" }
  catch { checkPlace }
}

# Top-level placement entry point.
proc pc::run_place {} {
  pc::run_place_step prects
}
