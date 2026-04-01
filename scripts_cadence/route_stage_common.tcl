# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# route_stage_common.tcl
# Shared helpers for staged route/postRoute flow:
#   route-only -> postroute-receive -> postroute-owner
# Each route stage is launched by its own Tcl entry script so the
# Makefile can bind a stage-specific LEF/COVER view explicitly.
# ============================================================

source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/handoff_manager.tcl

set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

proc route_copy_file_if_exists {src dst} {
  handoff_copy_file_if_exists $src $dst
}

proc route_stage_paths {stage results_dir objects_dir} {
  set log_dir [_get LOG_DIR]
  switch -- $stage {
    route-only {
      return [handoff_stage_paths "route-only" $results_dir $objects_dir $log_dir]
    }
    postroute-receive {
      return [handoff_stage_paths "postroute-receive" $results_dir $objects_dir $log_dir]
    }
    postroute-owner {
      return [handoff_stage_paths "postroute-owner" $results_dir $objects_dir $log_dir]
    }
    default {
      error "Unsupported staged route stage '$stage'."
    }
  }
}

proc route_init_design_from_paths {stage_paths} {
  dict with stage_paths {
    set use_restore 0
    if {[info exists enc_in] && $enc_in ne "" && [file exists $enc_in]} {
      set use_restore 1
    }

    if {$use_restore} {
      handoff_require_inputs $stage_paths {v_in sdc_in}

      # Some Innovus builds still expect init_* globals to be populated
      # before restoreDesign, even though the routed database is restored.
      handoff_prepare_init_globals $stage_paths

      puts "INFO: restoreDesign $enc_in $::DESIGN"
      restoreDesign $enc_in $::DESIGN
      _common_setup
      set_interactive_constraint_modes [all_constraint_modes -active]
      set_propagated_clock [all_clocks]
      set_clock_propagation propagated
      return
    }

    handoff_init_design_from_paths $stage_paths
    set_interactive_constraint_modes [all_constraint_modes -active]
    set_propagated_clock [all_clocks]
    set_clock_propagation propagated
  }
}

proc route_apply_common_layer_setup {} {
  if {[info exists ::env(MAX_ROUTING_LAYER)]} {
    setDesignMode -topRoutingLayer $::env(MAX_ROUTING_LAYER)
  }
  if {[info exists ::env(MIN_ROUTING_LAYER)]} {
    setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER)
  }
}

proc route_apply_router_setup {} {
  setNanoRouteMode -grouteExpWithTimingDriven false
  if {![info exists ::env(DETAILED_ROUTE_END_ITERATION)]} {
    set ::env(DETAILED_ROUTE_END_ITERATION) 20
  }
  setNanoRouteMode -drouteEndIteration $::env(DETAILED_ROUTE_END_ITERATION)
  setNanoRouteMode -drouteVerboseViolationSummary 1
  setNanoRouteMode -routeWithSiDriven true
  setNanoRouteMode -routeWithTimingDriven true
  setNanoRouteMode -routeUseAutoVia true
  setNanoRouteMode -routeWithViaInPin "1:1"
  setNanoRouteMode -routeWithViaOnlyForStandardCellPin "1:1"
  setNanoRouteMode -drouteOnGridOnly "via 1:1"
  setNanoRouteMode -drouteAutoStop false
  setNanoRouteMode -drouteExpAdvancedMarFix true
  setNanoRouteMode -routeExpAdvancedTechnology true
}

proc route_write_stage_outputs {stage_paths} {
  handoff_write_stage_outputs $stage_paths \
    -def_args {-netlist -floorplan -routing} \
    -copy_sdc 1 \
    -save_design 1 \
    -write_png 1 \
    -write_manifest 1
}
