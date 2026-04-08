# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# open_handoff_gui.tcl
# Load a staged Cadence handoff into Innovus GUI.
# ============================================================

set pin3d_scripts_dir [file dirname [file normalize [info script]]]
set ::env(CADENCE_SCRIPTS_DIR) $pin3d_scripts_dir

if {![info exists ::env(HANDOFF_TCL)] || $::env(HANDOFF_TCL) eq ""} {
  puts stderr "ERROR: HANDOFF_TCL is not set."
  exit 1
}

source [file join $::env(CADENCE_SCRIPTS_DIR) utils.tcl]

proc pin3d_normalize_optional {path} {
  if {$path eq ""} {
    return ""
  }
  return [file normalize $path]
}

proc pin3d_dict_get {record key {default ""}} {
  if {[dict exists $record $key]} {
    return [dict get $record $key]
  }
  return $default
}

proc pin3d_view_mode {} {
  if {[info exists ::env(HANDOFF_VIEW)] && $::env(HANDOFF_VIEW) ne ""} {
    return [string tolower $::env(HANDOFF_VIEW)]
  }
  return "auto"
}

proc pin3d_existing_enc_candidate {path} {
  if {$path eq ""} {
    return ""
  }

  set candidates [list $path]
  if {[file extension $path] ne ".dat"} {
    lappend candidates "${path}.dat"
  }

  foreach candidate $candidates {
    set normalized [pin3d_normalize_optional $candidate]
    if {[file exists $normalized]} {
      return $normalized
    }
  }

  return ""
}

proc pin3d_select_design_input {record} {
  set view [pin3d_view_mode]

  set enc_in [pin3d_dict_get $record enc_in]
  set enc_out [pin3d_dict_get $record enc_out]
  set def_in [pin3d_dict_get $record def_in]
  set def_out [pin3d_dict_get $record def_out]

  switch -- $view {
    in {
      set enc_candidates [list $enc_in $enc_out]
      set def_candidates [list $def_in $def_out]
    }
    out {
      set enc_candidates [list $enc_out $enc_in]
      set def_candidates [list $def_out $def_in]
    }
    default {
      set enc_candidates [list $enc_out $enc_in]
      set def_candidates [list $def_out $def_in]
    }
  }

  foreach candidate $enc_candidates {
    set enc_path [pin3d_existing_enc_candidate $candidate]
    if {$enc_path ne ""} {
      return [list enc $enc_path]
    }
  }

  foreach candidate $def_candidates {
    if {$candidate eq ""} {
      continue
    }
    set normalized [pin3d_normalize_optional $candidate]
    if {[file exists $normalized]} {
      return [list def $normalized]
    }
  }

  return [list "" ""]
}

proc pin3d_select_verilog_input {record} {
  set view [pin3d_view_mode]

  switch -- $view {
    in {
      set candidates [list [pin3d_dict_get $record v_in] [pin3d_dict_get $record v_out]]
    }
    out {
      set candidates [list [pin3d_dict_get $record v_out] [pin3d_dict_get $record v_in]]
    }
    default {
      set candidates [list [pin3d_dict_get $record v_out] [pin3d_dict_get $record v_in]]
    }
  }

  foreach candidate $candidates {
    if {$candidate eq ""} {
      continue
    }
    set normalized [pin3d_normalize_optional $candidate]
    if {[file exists $normalized]} {
      return $normalized
    }
  }

  return ""
}

proc pin3d_select_sdc_input {record} {
  set view [pin3d_view_mode]

  switch -- $view {
    in {
      set candidates [list [pin3d_dict_get $record sdc_in] [pin3d_dict_get $record sdc_out]]
    }
    out {
      set candidates [list [pin3d_dict_get $record sdc_out] [pin3d_dict_get $record sdc_in]]
    }
    default {
      set candidates [list [pin3d_dict_get $record sdc_out] [pin3d_dict_get $record sdc_in]]
    }
  }

  foreach candidate $candidates {
    if {$candidate eq ""} {
      continue
    }
    set normalized [pin3d_normalize_optional $candidate]
    if {[file exists $normalized]} {
      return $normalized
    }
  }

  return ""
}

proc pin3d_restore_or_init_design {design_kind design_path verilog_file design_name} {
  global lefs
  global sdc

  set ::init_lef_file $lefs
  set ::init_mmmc_file ""
  set ::init_design_settop 1
  set ::init_top_cell $design_name

  if {$verilog_file ne ""} {
    set ::init_verilog $verilog_file
    set ::init_design_netlisttype "Verilog"
  }

  switch -- $design_kind {
    enc {
      puts "INFO: restoreDesign $design_path $design_name"
      restoreDesign $design_path $design_name
    }
    def {
      if {$verilog_file eq ""} {
        puts stderr "ERROR: DEF GUI load requires a matching Verilog handoff."
        exit 1
      }
      init_design -setup {WC_VIEW} -hold {BC_VIEW}
      defIn $design_path
    }
    default {
      puts stderr "ERROR: unsupported design input kind '$design_kind'"
      exit 1
    }
  }

  _common_setup
  catch {set_interactive_constraint_modes [all_constraint_modes -active]}
  catch {set_propagated_clock [all_clocks]}
  catch {set_clock_propagation propagated}
}

set handoff_tcl [file normalize $::env(HANDOFF_TCL)]
if {![file exists $handoff_tcl]} {
  puts stderr "ERROR: handoff manifest not found: $handoff_tcl"
  exit 1
}

namespace eval ::handoff {}
catch {unset ::handoff::record}
source $handoff_tcl
if {![info exists ::handoff::record]} {
  puts stderr "ERROR: handoff manifest did not define ::handoff::record"
  exit 1
}

set handoff_record $::handoff::record
set stage_name [pin3d_dict_get $handoff_record stage]
set stage_label [pin3d_dict_get $handoff_record stage_label $stage_name]
set design_name [pin3d_dict_get $handoff_record design [_get DESIGN_NAME]]

foreach key {results_dir objects_dir log_dir} {
  set value [pin3d_dict_get $handoff_record $key]
  if {$value ne ""} {
    set ::env([string toupper $key]) [pin3d_normalize_optional $value]
  }
}

set design_choice [pin3d_select_design_input $handoff_record]
set design_kind [lindex $design_choice 0]
set design_path [lindex $design_choice 1]
set verilog_file [pin3d_select_verilog_input $handoff_record]
set sdc_file [pin3d_select_sdc_input $handoff_record]

if {$design_kind eq "" || $design_path eq ""} {
  puts stderr "ERROR: no existing ENC/DEF found in handoff manifest: $handoff_tcl"
  exit 1
}
if {$sdc_file eq ""} {
  puts stderr "ERROR: no existing SDC found in handoff manifest: $handoff_tcl"
  exit 1
}
if {$design_name eq ""} {
  puts stderr "ERROR: DESIGN_NAME is not available for GUI load."
  exit 1
}

set ::env(SDC_FILE) $sdc_file

source [file join $::env(CADENCE_SCRIPTS_DIR) lib_setup.tcl]
set sdc $sdc_file
source [file join $::env(CADENCE_SCRIPTS_DIR) mmmc_setup.tcl]

puts "INFO\[GUI\]: handoff=$handoff_tcl"
puts "INFO\[GUI\]: stage=$stage_name label=$stage_label"
puts "INFO\[GUI\]: design_name=$design_name"
puts "INFO\[GUI\]: design_kind=$design_kind"
puts "INFO\[GUI\]: design_path=$design_path"
puts "INFO\[GUI\]: sdc_file=$sdc_file"
if {$verilog_file ne ""} {
  puts "INFO\[GUI\]: verilog_file=$verilog_file"
}
if {[info exists ::env(LEF_FILES)]} {
  puts "INFO\[GUI\]: lef_view=$::env(LEF_FILES)"
}

pin3d_restore_or_init_design $design_kind $design_path $verilog_file $design_name

catch {fit}
catch {win}
puts "INFO\[GUI\]: GUI is ready. Type 'resume' in the Innovus console to release the script."
suspend
