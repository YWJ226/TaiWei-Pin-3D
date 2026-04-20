proc _or_capture_cmd_to_file {rpt script_body} {
  if {[llength [info commands redirect]] > 0} {
    redirect -file $rpt $script_body
  } else {
    set txt [uplevel 1 $script_body]
    set fh [open $rpt w]
    puts $fh $txt
    close $fh
  }
}

proc _parse_first_match {path regex} {
  if {![file exists $path]} {
    return ""
  }
  set fh [open $path r]
  set value ""
  while {[gets $fh line] >= 0} {
    if {[regexp -- $regex $line _ hit]} {
      set value $hit
      break
    }
  }
  close $fh
  return $value
}

proc _parse_total_power_from_finish_report {path} {
  return [_parse_first_match $path {^Total\s+\S+\s+\S+\s+\S+\s+(\S+)}]
}

proc _parse_wire_length_from_report {path} {
  if {![file exists $path]} {
    return ""
  }
  set fh [open $path r]
  set total 0.0
  set matched 0
  while {[gets $fh line] >= 0} {
    set trimmed [string trim $line]
    if {$trimmed eq ""} {
      continue
    }
    if {[regexp {^drt:\s+\S+\s+([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\s+\d+} $trimmed _ hit]} {
      set total [expr {$total + double($hit)}]
      set matched 1
    }
  }
  close $fh
  if {!$matched} {
    return ""
  }
  return [_format_decimal $total 2]
}

proc _count_matches_in_file {path regex} {
  if {![file exists $path]} {
    return ""
  }
  set count 0
  set fh [open $path r]
  while {[gets $fh line] >= 0} {
    if {[regexp -- $regex $line]} {
      incr count
    }
  }
  close $fh
  return $count
}

proc _metric_or_na {value {default "N/A"}} {
  if {$value eq ""} {
    return $default
  }
  return $value
}

proc _format_decimal {value {digits 6}} {
  if {$value eq ""} {
    return ""
  }
  if {[catch {set formatted [format "%.${digits}f" [expr {double($value)}]]}]} {
    return $value
  }
  regsub {(\.[0-9]*?)0+$} $formatted {\1} formatted
  regsub {\.$} $formatted {} formatted
  return $formatted
}

proc _dbu_per_micron {} {
  set db [ord::get_db]
  if {$db eq "NULL"} {
    return 0
  }
  set tech [odb::dbDatabase_getTech $db]
  if {$tech eq "NULL"} {
    return 0
  }
  return [odb::dbTech_getDbUnitsPerMicron $tech]
}

proc _collect_openroad_area_metrics {} {
  set block [ord::get_db_block]
  set dbu [_dbu_per_micron]
  if {$block eq "NULL" || $dbu <= 0} {
    return [list "" "" ""]
  }

  set core_area ""
  set core [$block getCoreArea]
  if {$core ne "NULL"} {
    set core_area [expr {
      double(([$core xMax] - [$core xMin]) * ([$core yMax] - [$core yMin])) / double($dbu * $dbu)
    }]
  }

  set std_cell_area 0.0
  set macro_area 0.0
  foreach inst [$block getInsts] {
    set master [$inst getMaster]
    if {$master eq "NULL"} {
      continue
    }
    set inst_area [expr {
      double([$master getWidth]) * double([$master getHeight]) / double($dbu * $dbu)
    }]
    set master_type [$master getType]
    if {$master_type eq "BLOCK"} {
      set macro_area [expr {$macro_area + $inst_area}]
    } elseif {$master_type eq "CORE"} {
      set std_cell_area [expr {$std_cell_area + $inst_area}]
    }
  }

  return [list \
    [_format_decimal $core_area] \
    [_format_decimal $std_cell_area] \
    [_format_decimal $macro_area]]
}

proc _count_hb_vias_from_openroad_db {} {
  set block [ord::get_db_block]
  if {$block eq "NULL"} {
    return ""
  }

  set total 0
  set decoder [odb::dbWireDecoder]
  foreach net [$block getNets] {
    set wire [$net getWire]
    if {$wire eq "NULL"} {
      continue
    }

    $decoder begin $wire
    while {1} {
      set opcode [$decoder next]
      if {$opcode == $odb::dbWireDecoder_END_DECODE} {
        break
      }

      if {$opcode == $odb::dbWireDecoder_TECH_VIA} {
        set via_name [[$decoder getTechVia] getName]
      } elseif {$opcode == $odb::dbWireDecoder_VIA} {
        set via_name [[$decoder getVia] getName]
      } else {
        continue
      }

      if {[regexp {^hb_layer_[0-9]+$} $via_name]} {
        incr total
      }
    }
  }

  return $total
}

proc _count_route_drc_violations {path} {
  return [_count_matches_in_file $path {^violation type:}]
}

proc _parse_finish_erc_counts {finish_rpt} {
  set max_slew [_parse_first_match $finish_rpt {^max slew violation count (\S+)}]
  set max_cap [_parse_first_match $finish_rpt {^max cap violation count (\S+)}]
  set max_fanout [_parse_first_match $finish_rpt {^max fanout violation count (\S+)}]

  if {$max_slew eq "" || $max_cap eq "" || $max_fanout eq ""} {
    return [list "" "" "" ""]
  }

  set total [expr {int($max_slew) + int($max_cap) + int($max_fanout)}]
  return [list $max_slew $max_cap $max_fanout $total]
}

proc _parse_finish_fep_count {finish_rpt} {
  return [_parse_first_match $finish_rpt {^setup violation count (\S+)}]
}

proc _configure_openroad_power_activity_for_eval {} {
  if {[llength [info commands set_power_activity]] == 0} {
    return
  }

  # Match the default final-eval intent to a Cadence-like vectorless setup by
  # seeding primary inputs and sequential outputs together.
  set input_activity 0.2
  set duty 0.5
  set ff_output_activity 0.2

  set clocks [all_clocks]
  if {[llength $clocks] == 0} {
    puts "WARN(OR): skip power activity setup because no clocks are defined"
    return
  }

  catch {unset_power_activity -input}
  catch {unset_power_activity -global}

  puts "INFO(OR): set_power_activity -input -activity $input_activity -duty $duty"
  set_power_activity -input -activity $input_activity -duty $duty

  set ff_q_pins [all_registers -output_pins]
  if {[llength $ff_q_pins] == 0} {
    puts "WARN(OR): skip FF output activity setup because no register output pins were found"
  } else {
    catch {unset_power_activity -pins $ff_q_pins}
    puts "INFO(OR): set_power_activity -pins <[llength $ff_q_pins] register outputs> -activity $ff_output_activity -duty $duty"
    set_power_activity -pins $ff_q_pins -activity $ff_output_activity -duty $duty
  }
}

proc _write_openroad_final_summary {summary_path finish_rpt wire_rpt cross_tier_stats drc_rpt} {
  set wns [_parse_first_match $finish_rpt {^wns max (\S+)}]
  set tns [_parse_first_match $finish_rpt {^tns max (\S+)}]
  set total_power [_parse_total_power_from_finish_report $finish_rpt]
  set wire_length [_parse_wire_length_from_report $wire_rpt]
  lassign [_collect_openroad_area_metrics] core_area std_cell_area macro_area
  set hb_via_count [_count_hb_vias_from_openroad_db]
  set drc_violations [_count_route_drc_violations $drc_rpt]
  set fep_violations [_parse_finish_fep_count $finish_rpt]
  lassign [_parse_finish_erc_counts $finish_rpt] erc_max_slew erc_max_cap erc_max_fanout erc_total

  set fh [open $summary_path w]
  puts $fh "=== OpenROAD Pin3DFlow – Final Metrics ==="
  puts $fh "Out dir     : $::env(LOG_DIR)"
  puts $fh ""
  puts $fh [format "%-26s %s" "Core Area" [_metric_or_na $core_area]]
  puts $fh [format "%-26s %s" "StdCell Area" [_metric_or_na $std_cell_area]]
  puts $fh [format "%-26s %s" "Macro Area" [_metric_or_na $macro_area]]
  puts $fh [format "%-26s %s" "Total Power" [_metric_or_na $total_power]]
  puts $fh [format "%-26s %s" "Wire Length" [_metric_or_na $wire_length]]
  puts $fh [format "%-26s %s" "WNS" [_metric_or_na $wns]]
  puts $fh [format "%-26s %s" "TNS" [_metric_or_na $tns]]
  puts $fh [format "%-26s %s" "DRC Violations" [_metric_or_na $drc_violations]]
  puts $fh [format "%-26s %s" "FEP Violations" [_metric_or_na $fep_violations]]
  puts $fh [format "%-26s %s" "HB VIA Count (Phys)" [_metric_or_na $hb_via_count]]
  if {[dict size $cross_tier_stats] > 0} {
    puts $fh [format "%-26s %s" "Cross-Tier Nets (All)" [dict get $cross_tier_stats cross_tier_all]]
    puts $fh ""
    puts $fh "=== Cross-Tier Breakdown ==="
    puts $fh [format "%-26s %s" "Upper_Bottom" [dict get $cross_tier_stats upper_bottom]]
    puts $fh [format "%-26s %s" "Upper_IO" [dict get $cross_tier_stats upper_io]]
    puts $fh [format "%-26s %s" "Bottom_IO" [dict get $cross_tier_stats bottom_io]]
    puts $fh [format "%-26s %s" "Upper_Bottom_IO" [dict get $cross_tier_stats upper_bottom_io]]
    puts $fh [format "%-26s %s" "Unknown_Tier" [dict get $cross_tier_stats unknown]]
  }
  puts $fh ""
  puts $fh "=== ERC (Electrical: report_check_types) ==="
  puts $fh [format "%-26s %s" "Max Slew Violations" [_metric_or_na $erc_max_slew]]
  puts $fh [format "%-26s %s" "Max Cap Violations" [_metric_or_na $erc_max_cap]]
  puts $fh [format "%-26s %s" "Max Fanout Violations" [_metric_or_na $erc_max_fanout]]
  puts $fh [format "%-26s %s" "ERC Total (sum)" [_metric_or_na $erc_total]]
  close $fh
}
