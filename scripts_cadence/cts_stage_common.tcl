# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# cts_stage_common.tcl
# Shared helpers for staged 3D CTS:
#   owner-tree -> receive-opt -> finalize
# Each CTS stage is launched by its own Tcl entry script so the
# Makefile can bind a stage-specific LEF/COVER view explicitly.
# Public knobs:
#   CTS_LAYER
#   F2F_CTS_MODE
#   F2F_CTS_HANDOFFS_PER_DOMAIN
# ============================================================

if {![llength [info commands _get]]} {
  source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
}
if {![info exists ::lefs]} {
  source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
}
if {![info exists ::DESIGN]} {
  source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
}

set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

proc cts_owner_tier {} {
  if {[info exists ::env(CTS_LAYER)] && $::env(CTS_LAYER) ne ""} {
    return [string tolower $::env(CTS_LAYER)]
  }
  return "bottom"
}

proc cts_receive_tier {} {
  if {[cts_owner_tier] eq "upper"} {
    return "bottom"
  }
  return "upper"
}

proc cts_owner_allow_net {} {
  if {[cts_owner_tier] eq "upper"} {
    return "upper-only"
  }
  return "bottom-only"
}

proc cts_receive_allow_net {} {
  if {[cts_receive_tier] eq "upper"} {
    return "upper-only"
  }
  return "bottom-only"
}

proc cts_semantic_allow_net {semantic_name} {
  switch -- $semantic_name {
    owner_only {
      return [cts_owner_allow_net]
    }
    receive_only {
      return [cts_receive_allow_net]
    }
    all {
      return "all"
    }
    default {
      error "Unsupported CTS semantic allow_net '$semantic_name'."
    }
  }
}

proc cts_mode {} {
  if {[info exists ::env(F2F_CTS_MODE)] && $::env(F2F_CTS_MODE) ne ""} {
    return $::env(F2F_CTS_MODE)
  }
  return "single_trunk_handoff"
}

proc cts_handoffs_per_domain {} {
  if {[info exists ::env(F2F_CTS_HANDOFFS_PER_DOMAIN)] && $::env(F2F_CTS_HANDOFFS_PER_DOMAIN) ne ""} {
    return $::env(F2F_CTS_HANDOFFS_PER_DOMAIN)
  }
  return 1
}

proc cts_stage_paths {stage results_dir objects_dir} {
  switch -- $stage {
    owner-tree {
      return [dict create \
        def_in [file join $results_dir "3_place.def"] \
        v_in [file join $results_dir "3_place.v"] \
        sdc_in [file join $results_dir "3_place.sdc"] \
        def_out [file join $results_dir "4_0_cts_owner_tree.def"] \
        v_out [file join $results_dir "4_0_cts_owner_tree.v"] \
        sdc_out [file join $results_dir "4_0_cts_owner_tree.sdc"] \
        wrapper_v [file join $results_dir "4_0_cts_owner_tree.wrapper.v"] \
        wrapper_sdc [file join $results_dir "4_0_cts_owner_tree.wrapper.sdc"] \
        manifest [file join $results_dir "4_0_cts_handoff.manifest"] \
        enc_out [file join $objects_dir "${::DESIGN}_cts_owner_tree.enc"] \
        png_name "4_0_cts_owner_tree.png"]
    }
    receive-opt {
      return [dict create \
        def_in [file join $results_dir "4_0_cts_owner_tree.def"] \
        v_in [file join $results_dir "4_0_cts_owner_tree.v"] \
        sdc_in [file join $results_dir "4_0_cts_owner_tree.sdc"] \
        def_out [file join $results_dir "4_1_cts_receive_opt.def"] \
        v_out [file join $results_dir "4_1_cts_receive_opt.v"] \
        sdc_out [file join $results_dir "4_1_cts_receive_opt.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_cts_receive_opt.enc"] \
        png_name "4_1_cts_receive_opt.png"]
    }
    finalize {
      return [dict create \
        def_in [file join $results_dir "4_1_cts_receive_opt.def"] \
        v_in [file join $results_dir "4_1_cts_receive_opt.v"] \
        sdc_in [file join $results_dir "4_1_cts_receive_opt.sdc"] \
        def_out [file join $results_dir "4_3_cts_finalize.def"] \
        v_out [file join $results_dir "4_3_cts_finalize.v"] \
        sdc_out [file join $results_dir "4_3_cts_finalize.sdc"] \
        final_def_out [file join $results_dir "4_cts.def"] \
        final_v_out [file join $results_dir "4_cts.v"] \
        final_sdc_out [file join $results_dir "4_cts.sdc"] \
        enc_out [file join $objects_dir "${::DESIGN}_cts_finalize.enc"] \
        png_name "4_3_cts_finalize.png"]
    }
    default {
      error "Unsupported staged CTS stage '$stage'."
    }
  }
}

proc cts_copy_file_if_exists {src dst} {
  if {$src eq "" || $dst eq ""} {
    return
  }
  if {[file exists $src]} {
    file copy -force $src $dst
  }
}

proc cts_init_design_from_paths {stage_paths} {
  dict with stage_paths {
    if {![file exists $v_in]} {
      error "Missing staged CTS netlist: $v_in"
    }
    if {![file exists $def_in]} {
      error "Missing staged CTS DEF: $def_in"
    }

    # init_design consumes the global init_* variables. Keep the setup explicit
    # here so every staged CTS step validates its own handoff files.
    set ::init_lef_file $::lefs
    set ::init_mmmc_file ""
    set ::init_design_settop 1
    set ::init_top_cell $::DESIGN
    set ::init_verilog $v_in
    set ::init_design_netlisttype "Verilog"

    init_design -setup {WC_VIEW} -hold {BC_VIEW}
    _common_setup
    defIn $def_in
  }

  if {[info exists ::env(MAX_ROUTING_LAYER)]} {
    setDesignMode -topRoutingLayer $::env(MAX_ROUTING_LAYER)
  }
  if {[info exists ::env(MIN_ROUTING_LAYER)]} {
    setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER)
  }
}

proc cts_apply_common_ccopt_setup {} {
  set_ccopt_property post_conditioning_enable_routing_eco 1
  set_ccopt_property -cts_def_lock_clock_sinks_after_routing true
  setOptMode -unfixClkInstForOpt false
}

proc cts_write_handoff_manifest {path label} {
  set fh [open $path w]
  puts $fh "# Staged 3D CTS handoff manifest"
  puts $fh "label=$label"
  puts $fh "mode=[cts_mode]"
  puts $fh "owner_tier=[cts_owner_tier]"
  puts $fh "receive_tier=[cts_receive_tier]"
  puts $fh "handoffs_per_domain=[cts_handoffs_per_domain]"
  puts $fh "clocks=[join [_report_clock_names] { }]"
  close $fh
}

proc cts_write_wrapper_artifacts {stage_paths} {
  dict with stage_paths {
    if {[info exists wrapper_v]} {
      cts_copy_file_if_exists $v_in $wrapper_v
    }
    if {[info exists wrapper_sdc]} {
      cts_copy_file_if_exists $sdc_in $wrapper_sdc
    }
    if {[info exists manifest]} {
      cts_write_handoff_manifest $manifest "owner-tree"
    }
  }
}

proc cts_write_stage_outputs {stage_paths} {
  global LOG_DIR
  dict with stage_paths {
    defOut -floorplan -routing $def_out
    saveNetlist $v_out
    cts_copy_file_if_exists $sdc_in $sdc_out
    if {[info exists enc_out] && $enc_out ne ""} {
      saveDesign $enc_out
    }
    if {[info exists final_def_out]} {
      cts_copy_file_if_exists $def_out $final_def_out
    }
    if {[info exists final_v_out]} {
      cts_copy_file_if_exists $v_out $final_v_out
    }
    if {[info exists final_sdc_out]} {
      cts_copy_file_if_exists $sdc_out $final_sdc_out
    }
    fit
    if {[info exists png_name] && $png_name ne ""} {
      dumpToGIF [file join $LOG_DIR $png_name]
    }
  }
}
