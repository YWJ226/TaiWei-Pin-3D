# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# place_common.tcl — Stable pre-GR/pre-legal setup for Innovus placement
# Dependencies: utils.tcl / lib_setup.tcl / design_setup.tcl / mmmc_setup.tcl must be sourced.
# Environment Variables (Optional):
#   PAD_REGEX  : Regex for base cell names to add padding to (e.g., "BUF.*|INV.*")
#   PAD_LEFT   : Left padding in sites (default 0)
#   PAD_RIGHT  : Right padding in sites (default 0)
#   DISABLE_SCAN_REORDER : Set to 1 to disable scan reordering (default 1, more stable)
#   NON_TIMING_PLACE     : Set to 1 to disable timing-driven placement (default 0)
#   USE_PLACE_OPT        : Set to 1 to use place_opt_design (default 1)
#   USE_CONCURRENT_MACRO : Set to 1 for concurrent macro and standard cell placement (default 0; requires movable macros)
#   HONOR_INST_PAD       : Set to 1 to treat instance padding as a hard rule
#   MAX_ROUTING_LAYER / MIN_ROUTING_LAYER : Constrain routing layers
# ==========================================
# Ensure namespace exists
if {![namespace exists pc]} {
  namespace eval pc {
    namespace export common_setup setup_basic run_place
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

# Single-step: place_opt_design (recommended)
proc pc::run_place {} {
  set use_pod           [pc::_env_or USE_PLACE_OPT 1]
  set do_concurrent_mac [pc::_env_or USE_CONCURRENT_MACRO 0]

  if {$do_concurrent_mac} {
    puts "INFO\[pc\]: place_design -concurrent_macros"
    catch { place_design -concurrent_macros } msg
    if {[info exists msg] && $msg ne ""} { puts "INFO\[pc\]: $msg" }
  } else {
    puts "INFO\[pc\]: Skip concurrent_macros (disabled or no movable macros)."
  }

  if {$use_pod} {
    puts "INFO\[pc\]: place_opt_design (integrated preCTS opt)"
    # Report directory/prefix might be defined in your design script; provide a compatible fallback
    set reports_dir [expr {[info exists ::REPORTS_DIR] ? $::REPORTS_DIR : "./reports"}]
    file mkdir $reports_dir
    catch { place_opt_design -out_dir $reports_dir -prefix prects } msg
    if {[info exists msg] && $msg ne ""} { puts "INFO\[pc\]: $msg" }
  } else {
    puts "INFO\[pc\]: classic flow: place_design + optDesign -preCTS"
    catch { place_design }
    catch { optDesign -preCTS }
  }

  catch { checkPlace }
}
