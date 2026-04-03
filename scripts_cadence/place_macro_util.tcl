# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# place_macro_util.tcl
# Common helpers for die-by-die macro placement.
# The tier visibility and overlap behavior are defined by LEF views.
# This file does not create extra blockages for the opposite tier.
# ==========================================

if {![namespace exists pmu]} {
  namespace eval pmu {}
}

proc pmu::is_macro_like_inst {inst_ptr} {
  if {$inst_ptr eq "" || $inst_ptr eq "0x0"} {
    return 0
  }

  set sub_class [string tolower [dbGet $inst_ptr.cell.subClass]]
  set base_class [string tolower [dbGet $inst_ptr.cell.baseClass]]
  if {[string match "*block*" $sub_class] || [string match "*block*" $base_class]} {
    return 1
  }
  if {[string match "*ring*" $sub_class] || [string match "*ring*" $base_class]} {
    return 1
  }
  set site_name [dbGet $inst_ptr.cell.site.name]
  if {$site_name eq "" || $site_name eq "0x0"} {
    return 1
  }
  return 0
}

proc pmu::_get_halos {} {
  if {![info exists ::env(MACRO_PLACE_HALO)] || $::env(MACRO_PLACE_HALO) eq ""} {
    return [list 0 0]
  }
  lassign $::env(MACRO_PLACE_HALO) halo_x halo_y
  return [list $halo_x $halo_y]
}

proc pmu::_norm_tier {tier} {
  set t [string tolower $tier]
  if {$t ne "upper" && $t ne "bottom"} {
    error "pmu::_norm_tier: tier must be upper or bottom, got '$tier'"
  }
  return $t
}

proc pmu::get_tier_macro_cells {tier} {
  set t [pmu::_norm_tier $tier]
  set pat "*_${t}"
  set cells {}

  foreach inst [dbGet -p2 top.insts.cell.name $pat] {
    if {[pmu::is_macro_like_inst $inst]} {
      lappend cells [dbGet $inst.cell.name]
    }
  }

  return [lsort -unique $cells]
}

proc pmu::get_tier_macro_insts {tier} {
  set t [pmu::_norm_tier $tier]
  set pat "*_${t}"
  set insts {}
  foreach inst [dbGet -p2 top.insts.cell.name $pat] {
    if {[pmu::is_macro_like_inst $inst]} {
      lappend insts $inst
    }
  }
  return $insts
}

proc pmu::set_tier_macro_status {tier status} {
  set insts [pmu::get_tier_macro_insts $tier]
  if {![llength $insts]} {
    puts "INFO(PMU): No ${tier} macros found."
    return
  }
  dbSet $insts.pStatus $status
  puts "INFO(PMU): Set [llength $insts] ${tier} macros to '$status'."
}

proc pmu::set_all_tier_macros_fixed {} {
  pmu::set_tier_macro_status upper fixed
  pmu::set_tier_macro_status bottom fixed
}

proc pmu::run_tier_macro_place {tier halo_x halo_y} {
  addHaloToBlock -allMacro $halo_x $halo_y $halo_x $halo_y
  place_design -concurrent_macros
  refine_macro_place
  pmu::set_tier_macro_status $tier fixed
  puts "INFO(PMU): ${tier} macro placement done."
}

proc pmu::save_stage {def_out v_out png_out} {
  fit
  catch { dumpToGIF $png_out }
  defOut -floorplan $def_out
  saveNetlist $v_out
  puts "INFO(PMU): DEF -> $def_out"
  puts "INFO(PMU): V   -> $v_out"
}
