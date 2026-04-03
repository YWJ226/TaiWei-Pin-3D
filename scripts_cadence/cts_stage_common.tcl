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
source $::env(CADENCE_SCRIPTS_DIR)/handoff_manager.tcl

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
  return [_effective_allow_net_class [cts_owner_requested_allow_net] 1]
}

proc cts_receive_allow_net {} {
  return [_effective_allow_net_class [cts_receive_requested_allow_net] 1]
}

proc cts_owner_requested_allow_net {} {
  if {[cts_owner_tier] eq "upper"} {
    return [_normalize_allow_net_class "upper-only"]
  }
  return [_normalize_allow_net_class "bottom-only"]
}

proc cts_receive_requested_allow_net {} {
  if {[cts_receive_tier] eq "upper"} {
    return [_normalize_allow_net_class "upper-only"]
  }
  return [_normalize_allow_net_class "bottom-only"]
}

proc cts_semantic_allow_net {semantic_name} {
  switch -- $semantic_name {
    owner_only {
      return [cts_owner_requested_allow_net]
    }
    receive_only {
      return [cts_receive_requested_allow_net]
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
  set log_dir [_get LOG_DIR]
  switch -- $stage {
    owner-tree {
      return [handoff_stage_paths "cts-owner-tree" $results_dir $objects_dir $log_dir]
    }
    receive-opt {
      return [handoff_stage_paths "cts-receive-opt" $results_dir $objects_dir $log_dir]
    }
    finalize {
      return [handoff_stage_paths "cts-finalize" $results_dir $objects_dir $log_dir]
    }
    default {
      error "Unsupported staged CTS stage '$stage'."
    }
  }
}

proc cts_copy_file_if_exists {src dst} {
  handoff_copy_file_if_exists $src $dst
}

proc cts_init_design_from_paths {stage_paths} {
  handoff_init_design_from_paths $stage_paths
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
  cts_lock_all_macros
}

proc cts_lock_all_macros {} {
  if {![llength [info commands pmu::set_tier_macro_status]]} {
    puts "INFO: CTS macro lock skipped because pmu::set_tier_macro_status is unavailable."
    return
  }
  foreach tier {upper bottom} {
    pmu::set_tier_macro_status $tier fixed
  }
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
    if {$wrapper_v ne ""} {
      cts_copy_file_if_exists $v_in $wrapper_v
    }
    if {$wrapper_sdc ne ""} {
      cts_copy_file_if_exists $sdc_in $wrapper_sdc
    }
    set legacy_manifest [file join $results_dir "4_0_cts_handoff.manifest"]
    cts_write_handoff_manifest $legacy_manifest "owner-tree"
  }
}

proc cts_write_stage_outputs {stage_paths} {
  handoff_write_stage_outputs $stage_paths \
    -def_args {-floorplan -routing} \
    -copy_sdc 1 \
    -save_design 1 \
    -write_png 1 \
    -write_manifest 1 \
    -extra_manifest [list \
      cts_mode [cts_mode] \
      owner_tier [cts_owner_tier] \
      receive_tier [cts_receive_tier] \
      handoffs_per_domain [cts_handoffs_per_domain]]
}
