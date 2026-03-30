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

set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

proc route_copy_file_if_exists {src dst} {
  if {$src eq "" || $dst eq ""} {
    return
  }
  if {[file exists $src]} {
    file copy -force $src $dst
  }
}

proc route_stage_paths {stage results_dir objects_dir} {
  switch -- $stage {
    route-only {
      return [dict create \
        def_in [file join $results_dir "4_cts.def"] \
        v_in [file join $results_dir "4_cts.v"] \
        sdc_in [file join $results_dir "4_cts.sdc"] \
        def_out [file join $results_dir "5_0_route.def"] \
        v_out [file join $results_dir "5_0_route.v"] \
        sdc_out [file join $results_dir "5_0_route.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_route_only.enc"] \
        png_name "5_0_route.png"]
    }
    postroute-receive {
      return [dict create \
        enc_in [file join $objects_dir "${::DESIGN}_route_only.enc.dat"] \
        def_in [file join $results_dir "5_0_route.def"] \
        v_in [file join $results_dir "5_0_route.v"] \
        sdc_in [file join $results_dir "5_0_route.sdc"] \
        def_out [file join $results_dir "5_1_postroute_receive.def"] \
        v_out [file join $results_dir "5_1_postroute_receive.v"] \
        sdc_out [file join $results_dir "5_1_postroute_receive.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_postroute_receive.enc"] \
        png_name "5_1_postroute_receive.png"]
    }
    postroute-owner {
      return [dict create \
        def_in [file join $results_dir "5_1_postroute_receive.def"] \
        v_in [file join $results_dir "5_1_postroute_receive.v"] \
        sdc_in [file join $results_dir "5_1_postroute_receive.sdc"] \
        def_out [file join $results_dir "5_2_postroute_owner.def"] \
        v_out [file join $results_dir "5_2_postroute_owner.v"] \
        sdc_out [file join $results_dir "5_2_postroute_owner.sdc"] \
        final_def_out [file join $results_dir "5_route.def"] \
        final_v_out [file join $results_dir "5_route.v"] \
        final_sdc_out [file join $results_dir "5_route.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_postroute_owner.enc"] \
        png_name "5_2_postroute_owner.png"]
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
      if {![file exists $v_in]} {
        error "Missing staged route netlist for restore handoff: $v_in"
      }

      # Some Innovus builds still expect init_* globals to be populated
      # before restoreDesign, even though the routed database is restored.
      set ::init_lef_file $::lefs
      set ::init_mmmc_file ""
      set ::init_design_settop 1
      set ::init_top_cell $::DESIGN
      set ::init_verilog $v_in
      set ::init_design_netlisttype "Verilog"

      puts "INFO: restoreDesign $enc_in $::DESIGN"
      restoreDesign $enc_in $::DESIGN
      _common_setup
      set_interactive_constraint_modes [all_constraint_modes -active]
      set_propagated_clock [all_clocks]
      set_clock_propagation propagated
      return
    }

    if {![file exists $v_in]} {
      error "Missing staged route netlist: $v_in"
    }
    if {![file exists $def_in]} {
      error "Missing staged route DEF: $def_in"
    }

    # init_design consumes the global init_* variables. Keep the handoff
    # explicit so every route/postRoute stage validates its checkpoint inputs.
    set ::init_lef_file $::lefs
    set ::init_mmmc_file ""
    set ::init_design_settop 1
    set ::init_top_cell $::DESIGN
    set ::init_verilog $v_in
    set ::init_design_netlisttype "Verilog"

    init_design -setup {WC_VIEW} -hold {BC_VIEW}
    _common_setup
    set_interactive_constraint_modes [all_constraint_modes -active]
    set_propagated_clock [all_clocks]
    set_clock_propagation propagated
    defIn $def_in
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
  global LOG_DIR
  dict with stage_paths {
    defOut -netlist -floorplan -routing $def_out
    saveNetlist $v_out
    route_copy_file_if_exists $sdc_in $sdc_out
    if {[info exists final_def_out]} {
      route_copy_file_if_exists $def_out $final_def_out
    }
    if {[info exists final_v_out]} {
      route_copy_file_if_exists $v_out $final_v_out
    }
    if {[info exists final_sdc_out]} {
      route_copy_file_if_exists $sdc_out $final_sdc_out
    }
    if {[info exists enc_out] && $enc_out ne ""} {
      saveDesign $enc_out
    }
    fit
    if {[info exists png_name] && $png_name ne ""} {
      dumpToGIF [file join $LOG_DIR $png_name]
    }
  }
}
