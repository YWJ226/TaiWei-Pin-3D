# ============================================================
# cts_stage_common.tcl
# Shared helpers for staged OpenROAD CTS:
#   ord-cts      -> owner-tree construction
#   ord-cts-post -> receive-tier post-CTS optimization
# Public target names and handoff filenames stay unchanged.
# ============================================================

if {![llength [info commands or_cts_owner_tier]] || ![llength [info commands apply_tier_policy]] || ![llength [info commands mark_insts_by_master]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
}

proc or_cts_receive_tier {} {
  return [or_cts_fix_tier]
}

proc or_cts_requested_allow_net {tier} {
  switch -- $tier {
    upper {
      return "upper-only"
    }
    bottom {
      return "bottom-only"
    }
    default {
      error "Unsupported CTS tier '$tier'"
    }
  }
}

proc or_cts_effective_allow_net {tier} {
  return [_effective_allow_net_class [or_cts_requested_allow_net $tier] 1]
}

proc or_cts_tier_master_pattern {tier} {
  switch -- $tier {
    upper {
      return "*_upper"
    }
    bottom {
      return "*_bottom"
    }
    default {
      return ""
    }
  }
}

proc or_cts_set_fixed_tier_status {tier status {quiet 0}} {
  set pattern [or_cts_tier_master_pattern $tier]
  if {$pattern eq ""} {
    return
  }
  if {!$quiet} {
    puts "INFO(OR): CTS staged placement status tier=$tier pattern=$pattern status=$status"
  }
  mark_insts_by_master $pattern $status
}

proc or_cts_report_stage_banner {stage_label active_tier fixed_tier requested_allow_net effective_allow_net} {
  puts "INFO(OR): staged CTS stage='$stage_label' owner_tier=[or_cts_owner_tier] receive_tier=[or_cts_receive_tier] active_tier=$active_tier fixed_tier=$fixed_tier requested_allow_net=$requested_allow_net effective_allow_net=$effective_allow_net"
}

proc or_cts_common_args {} {
  set cts_args [list -sink_clustering_enable]
  append_env_var cts_args CTS_BUF_DISTANCE -distance_between_buffers 1
  append_env_var cts_args CTS_BUF_LIST -buf_list 1
  append_env_var cts_args CTS_LIB_NAME -library 1

  if {[env_var_exists_and_non_empty CTS_ARGS]} {
    set cts_args $::env(CTS_ARGS)
  } else {
    # Let TritonCTS auto-pick clustering when the user does not force it.
    append_env_var cts_args CTS_CLUSTER_SIZE -sink_clustering_size 1
    append_env_var cts_args CTS_CLUSTER_DIAMETER -sink_clustering_max_diameter 1
    if {[info exists ::env(OPENROAD_CTS_REPAIR_CLOCK_NETS_IN_CTS)]} {
      if {$::env(OPENROAD_CTS_REPAIR_CLOCK_NETS_IN_CTS)} {
        lappend cts_args -repair_clock_nets
      }
    } else {
      lappend cts_args -repair_clock_nets
    }
  }
  return $cts_args
}
