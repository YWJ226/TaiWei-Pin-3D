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
  set value ""
  while {[gets $fh line] >= 0} {
    set trimmed [string trim $line]
    if {$trimmed eq ""} {
      continue
    }
    if {[regexp {([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\s*$} $trimmed _ hit]} {
      set value $hit
    }
  }
  close $fh
  return $value
}

proc _write_openroad_final_summary {summary_path finish_rpt wire_rpt cross_tier_stats} {
  set wns [_parse_first_match $finish_rpt {^wns max (\S+)}]
  set tns [_parse_first_match $finish_rpt {^tns max (\S+)}]
  set total_power [_parse_total_power_from_finish_report $finish_rpt]
  set wire_length [_parse_wire_length_from_report $wire_rpt]

  set fh [open $summary_path w]
  puts $fh "=== OpenROAD Pin3DFlow – Final Metrics ==="
  puts $fh "Out dir     : $::env(LOG_DIR)"
  puts $fh ""
  puts $fh [format "%-26s %s" "WNS" $wns]
  puts $fh [format "%-26s %s" "TNS" $tns]
  puts $fh [format "%-26s %s" "Total Power" $total_power]
  puts $fh [format "%-26s %s" "Wire Length" $wire_length]
  if {[dict size $cross_tier_stats] > 0} {
    puts $fh [format "%-26s %s" "Cross-Tier Nets (All)" [dict get $cross_tier_stats cross_tier_all]]
    puts $fh [format "%-26s %s" "Cross Upper_Bottom" [dict get $cross_tier_stats upper_bottom]]
    puts $fh [format "%-26s %s" "Cross Upper_IO" [dict get $cross_tier_stats upper_io]]
    puts $fh [format "%-26s %s" "Cross Bottom_IO" [dict get $cross_tier_stats bottom_io]]
    puts $fh [format "%-26s %s" "Cross Upper_Bottom_IO" [dict get $cross_tier_stats upper_bottom_io]]
    puts $fh [format "%-26s %s" "Cross Unknown_Tier" [dict get $cross_tier_stats unknown]]
  }
  close $fh
}