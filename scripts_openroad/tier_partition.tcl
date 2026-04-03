# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2019-2025, The OpenROAD Authors
#
# ------------------------------------------------------------
# SIMPLE TritonPart sweep (single-process, N points)
#
# Two mutually-exclusive modes (both run N=PAR_BAL_ITERATION times):
#
# Mode A) PAR_SCALE_FACTOR is set (e.g. "0.05 0.95"):
#   - Treat PAR_SCALE_FACTOR as the CENTER/target of base_balance
#   - Scan base_balance around the center:
#       delta in [0.01 .. 0.06], N points (includes endpoints)
#       base_balance = {b0_center + delta, b1_center - delta}
#   - UB (balance_constraint) is FIXED to 1.0
#   - Selection policy:
#       prefer realized partition area ratio closest to the ORIGINAL center target
#       then prefer smaller cut
#   - Pin policy for cut evaluation:
#       assign all top-level pins to the larger realized partition
#       tie-break by larger base_balance, then partition 0
#
# Mode B) PAR_SCALE_FACTOR is not set:
#   - Scan UB (balance_constraint) uniformly on [PAR_BAL_LO .. PAR_BAL_HI], N points
#   - base_balance is FIXED to {0.5 0.5}
#   - Selection policy:
#       look at cut only
#   - Pin policy for cut evaluation:
#       assign all top-level pins to a fixed partition (default: 0)
#
# Inputs (env) [ONLY these partition knobs are read]:
#   - PAR_BAL_LO, PAR_BAL_HI
#   - PAR_BAL_ITERATION (N)
#   - PAR_SCALE_FACTOR  (two floats that sum to 1.0; enables Mode A)
#
# Extra cut-evaluation knob:
#   - PIN_PARTITION_MODE_B (optional, default 0)
#
# Outputs:
#   - $RESULTS_DIR/partition.txt
#   - $RESULTS_DIR/partition.result.tcl
#   - $RESULTS_DIR/partition.simple_plan.txt
#   - $RESULTS_DIR/partition_sweep/part.*.seed*.txt (+ optional cut_nets dumps)
# ------------------------------------------------------------
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

if {![llength [info commands evaluate_candidate]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/tier_partition_helpers.tcl
}

# Target cut budget from hb_layer density
# ------------------------------------------------------------
puts [format {INFO %s: HB layer=%s width=%.3fum spacing=%.3fum (pitch=%.3fum) density=%.3f cuts_per_net=%d tol=%d} \
  [_ts] $::HB_CUT_LAYER $::HB_LAYER_WIDTH_UM $::HB_LAYER_SPACING_UM \
  [expr {$::HB_LAYER_WIDTH_UM + $::HB_LAYER_SPACING_UM}] \
  $::HB_VIA_DENSITY $::CUTS_PER_NET $::CUT_TOL]
flush stdout

set pitch_x [expr {$::HB_LAYER_WIDTH_UM + $::HB_LAYER_SPACING_UM}]
set pitch_y [expr {$::HB_LAYER_WIDTH_UM + $::HB_LAYER_SPACING_UM}]
lassign [get_die_wh_area_um2] die_w die_h die_area
puts [format {INFO %s: DIE w=%.3fum h=%.3fum area=%.3fum^2} [_ts] $die_w $die_h $die_area]
flush stdout
lassign [estimate_max_hb_cuts_from_pitch $die_area $pitch_x $pitch_y $::HB_VIA_DENSITY] grid nmax
set target_cut [expr {int(floor(double($nmax) / double($::CUTS_PER_NET)))}]
puts [format {STAT %s: grid=%d max_hb_cuts=%d => CUT_NET_BUDGET(target)=%d} \
  [_ts] $grid $nmax $target_cut]
flush stdout

# ------------------------------------------------------------
# Decide mode + build N points
# ------------------------------------------------------------
set mode "UB_SWEEP"
set center_bb {}
set target_balance {}
if {[info exists ::env(PAR_SCALE_FACTOR)] && $::env(PAR_SCALE_FACTOR) ne ""} {
  set center_bb $::env(PAR_SCALE_FACTOR)
  _validate_float_list_sum1 "PAR_SCALE_FACTOR(as base_balance center)" $center_bb 2
  set mode "BB_SWEEP"
  set target_balance $center_bb
} else {
  set target_balance [list "0.500000" "0.500000"]
}

set out_dir [file join $::env(RESULTS_DIR) partition_sweep]
file mkdir $out_dir
puts [format {INFO %s: Solve-time pin constraints are disabled by design. Pin handling is evaluation-only.} [_ts]]
flush stdout

set plan_file [file join $::env(RESULTS_DIR) partition.simple_plan.txt]
set plan "PARTITION SWEEP @ [_ts]\n"
append_plan_line plan "floorplan_def=$fp_def"
append_plan_line plan [format "mode=%s N=%d seed=%d timing_aware=true" $mode $::PAR_BAL_ITER $::PAR_FIXED_SEED]
append_plan_line plan [format "target_cut=%d tol=%d" $target_cut $::CUT_TOL]
append_plan_line plan [format "target_balance=%s" $target_balance]
append_plan_line plan [format "mode_b_pin_partition=%d" $::PIN_PARTITION_MODE_B]
append_plan_line plan "solve_time_pin_constraints=disabled"
append_plan_line plan "pin_handling=evaluation_only"

set points {}

if {$mode eq "BB_SWEEP"} {
  set ub_fixed 1.0

  set b0c [expr {double([lindex $center_bb 0])}]
  set b1c [expr {double([lindex $center_bb 1])}]

  set d_lo 0.01
  set d_hi 0.06
  if {$::PAR_BAL_ITER == 1} {
    utl::error PAR 966 "PAR_BAL_ITERATION must be >= 2 for BB sweep."
  }
  set d_step [expr {($d_hi - $d_lo) / double($::PAR_BAL_ITER - 1)}]

  set bb_points {}
  for {set i 0} {$i < $::PAR_BAL_ITER} {incr i} {
    set d [expr {$d_lo + double($i)*$d_step}]
    if {$i == ($::PAR_BAL_ITER - 1)} { set d $d_hi }

    set b0 [expr {$b0c + $d}]
    set b1 [expr {$b1c - $d}]
    set b0 [_clamp01 $b0]
    set b1 [_clamp01 $b1]
    set s  [expr {$b0 + $b1}]
    if {$s <= 0.0} { utl::error PAR 981 [format "Invalid base_balance at delta %.6f: {%g %g}" $d $b0 $b1] }
    set b0 [expr {$b0 / $s}]
    set b1 [expr {$b1 / $s}]

    set b0s [format "%.6f" $b0]
    set b1s [format "%.6f" $b1]
    set ds  [format "%.6f" $d]
    set base_balance [list $b0s $b1s]

    set bb_tag [string map {. p} $b0s]
    lappend points [dict create ub $ub_fixed base_balance $base_balance tag "bb${bb_tag}" delta $ds]
    lappend bb_points [format "{%s %s}(d=%s)" $b0s $b1s $ds]
  }

  append_plan_line plan [format "PAR_SCALE_FACTOR(center)=%s" $center_bb]
  append_plan_line plan "UB fixed = 1.000000"
  append_plan_line plan [format "delta_scan=\[0.01..0.06\] points=%s" [join $bb_points ", "]]
  append_plan_line plan "selection_policy=prefer_feasible_then_target_balance_err_then_cut_then_ub"
  append_plan_line plan "pin_cut_policy=mode_a_use_larger_realized_partition"

} else {
  set base_balance [list "0.500000" "0.500000"]

  set span [expr {$::PAR_BAL_HI - $::PAR_BAL_LO}]
  if {$span <= 0.0} {
    utl::error PAR 963 [format "Invalid UB sweep range: lo=%.6f hi=%.6f" $::PAR_BAL_LO $::PAR_BAL_HI]
  }
  set step [expr {$span / double($::PAR_BAL_ITER - 1)}]
  if {$step <= 0.0} { utl::error PAR 964 [format "Invalid UB step: %.6f" $step] }

  set ub_points {}
  for {set i 0} {$i < $::PAR_BAL_ITER} {incr i} {
    set ub [expr {$::PAR_BAL_LO + double($i)*$step}]
    if {$i == ($::PAR_BAL_ITER - 1)} { set ub $::PAR_BAL_HI }
    set ubs [format "%.6f" $ub]
    lappend points [dict create ub $ub base_balance $base_balance tag "ub${ubs}" delta ""]
    lappend ub_points $ubs
  }

  append_plan_line plan [format "UB scan lo=%.6f hi=%.6f points=%s" $::PAR_BAL_LO $::PAR_BAL_HI [join $ub_points ","]]
  append_plan_line plan "base_balance fixed = {0.5 0.5}"
  append_plan_line plan "selection_policy=prefer_feasible_then_cut_then_ub"
  append_plan_line plan [format "pin_cut_policy=mode_b_fixed_partition_%d" $::PIN_PARTITION_MODE_B]
}

set fh [open $plan_file w]
puts $fh $plan
close $fh

puts [format {INFO %s: mode=%s N=%d plan=%s} [_ts] $mode $::PAR_BAL_ITER $plan_file]
flush stdout

set best ""

foreach p $points {
  set cur [evaluate_candidate $p $mode $target_balance $target_cut $out_dir]

  if {$best eq "" || [candidate_better $cur $best $mode]} {
    set best $cur
  }
}

if {$best eq ""} { utl::error PAR 962 "No valid sweep result." }

# ------------------------------------------------------------
# Finalize
# ------------------------------------------------------------
set final_sol [file join $::env(RESULTS_DIR) partition.txt]
file copy -force [dict get $best solution_file] $final_sol

set final_sum [file join $::env(RESULTS_DIR) partition.result.tcl]
set sum_dict [dict create \
  mode [dict get $best mode] \
  seed $::PAR_FIXED_SEED \
  timing_aware true \
  N $::PAR_BAL_ITER \
  PAR_BAL_LO $::PAR_BAL_LO \
  PAR_BAL_HI $::PAR_BAL_HI \
  PAR_SCALE_FACTOR $center_bb \
  target $target_cut \
  tol $::CUT_TOL \
  target_balance $target_balance \
  best_tag [dict get $best tag] \
  best_ub [dict get $best ub] \
  best_base_balance [dict get $best base_balance] \
  best_pin_partition [dict get $best pin_partition] \
  best_cut [dict get $best cut] \
  best_feasible [dict get $best feasible] \
  best_abs_diff [dict get $best abs_diff] \
  best_ratio0 [dict get $best ratio0] \
  best_ratio1 [dict get $best ratio1] \
  best_balance_err [dict get $best balance_err] \
  solution_file [dict get $best solution_file] \
  sweep_dir $out_dir \
  plan_file $plan_file]
write_kv_file $final_sum $sum_dict

puts [format {INFO %s: FINAL mode=%s best_tag=%s ub=%.6f base_balance=%s pin_partition=%d target_balance=%s cut=%d feasible=%s area_ratio={%.6f %.6f} target_balance_err=%.6f -> %s} \
  [_ts] [dict get $best mode] [dict get $best tag] [dict get $best ub] [dict get $best base_balance] \
  [dict get $best pin_partition] \
  [dict get $best target_balance] [dict get $best cut] [dict get $best feasible] \
  [dict get $best ratio0] [dict get $best ratio1] [dict get $best balance_err] $final_sol]
puts [format {INFO %s: summary=%s} [_ts] $final_sum]
flush stdout

exit
