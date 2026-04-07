# ============================================================
# OpenROAD Tcl
# File: split_net.tcl
# Regular-buffer split pass for mixed-tier signal nets.
#
# This matches the Cadence split-net intent:
#   driver -> original_net -> retained sinks + buffer input
#   buffer -> branch_net   -> moved sinks
#
# The pass runs after IO placement and before macro placement. It does not
# require a special 1-input/2-output splitter cell; it uses a regular 1-input
# / 1-output buffer on the selected tier.
# ============================================================

if {![llength [info commands _or_bterm_tier]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
}

namespace eval ::tier_split_or2 {
  variable CFG
  variable NAME_SET
  variable MASTER_LOOKUP
  variable BUFFER_MASTER_CHOICES
  variable INST_TIER_CACHE
  variable ITERM_TIER_CACHE
  variable BTERM_TIER_CACHE
  variable TIER_UTILIZATION
  array set CFG {
    split_y_um               0.0
    use_bbox_split           1
    dry_run                  1
    report_file              tier_split_buffer_openroad.rpt
    manifest_file            {}
    dump_cell_tier           0
    dump_pin_tier            0
    log_skip_details         0

    upper_inst_re            {}
    lower_inst_re            {}
    upper_pin_re             {}
    lower_pin_re             {}

    upper_master_re          {_upper$}
    lower_master_re          {_bottom$|_lower$}

    buffer_master_upper_re   {}
    buffer_master_lower_re   {}

    buffer_inst_suffix       __SPLITBUF__
    branch_net_suffix        __BRANCH

    require_both_sink_tiers  1
    skip_port_driven_nets    1
    skip_clock_nets          1
    util_safe                0.60
    util_alpha               12.0
    util_weight              1.0
    hbt_weight               2.5
    area_weight              400.0
    high_util_forbid         0.8
    near_tie_ratio           0.05
  }
  array set NAME_SET {}
  array set MASTER_LOOKUP {}
  array set BUFFER_MASTER_CHOICES {}
  array set INST_TIER_CACHE {}
  array set ITERM_TIER_CACHE {}
  array set BTERM_TIER_CACHE {}
  set TIER_UTILIZATION {}
}


if {![llength [info commands ::tier_split_or2::run]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/split_net_impl.tcl
}
