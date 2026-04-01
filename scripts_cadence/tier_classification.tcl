# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# tier_classification.tcl
# Shared tier classification helpers for staged 3D Cadence flow.
# Rules:
#   - instance tier comes from master / instance suffix naming
#   - top-level IO term tier comes from actual placed pin routing layers
#   - layers ending with "_m" belong to upper
#   - non "_m" routing layers belong to bottom
#   - hb_layer and ambiguous layer sets are treated as unknown
# ============================================================

if {[info exists ::tier_classification_loaded] && $::tier_classification_loaded} {
  return
}
set ::tier_classification_loaded 1

proc tier_is_upper_tag {s} {
  expr {[string match "*_upper" $s]}
}

proc tier_is_bottom_tag {s} {
  expr {[string match "*_bottom" $s]}
}

proc tier_is_split_buffer_name {s} {
  expr {[string match "SPLITBUF*" [string trim $s]]}
}

proc tier_layer_to_tier {layer_name} {
  set layer_name [string trim $layer_name]
  if {$layer_name eq ""} {
    return "unknown"
  }

  set lname [string tolower $layer_name]
  if {$lname eq "hb_layer"} {
    return "unknown"
  }
  if {[string match "*_m" $lname]} {
    return "upper"
  }
  return "bottom"
}

proc tier_term_routing_layers {term_ptr} {
  set layers {}
  foreach layer [dbGet -e $term_ptr.pins.allShapes.layer.name] {
    if {$layer eq ""} {
      continue
    }
    set lname [string tolower $layer]
    if {$lname eq "hb_layer"} {
      continue
    }
    if {[string match "via*" $lname]} {
      continue
    }
    lappend layers $layer
  }
  return [lsort -unique $layers]
}

proc tier_classify_inst_ptr {inst_ptr} {
  if {$inst_ptr eq "" || $inst_ptr eq "0x0"} {
    return "unknown"
  }

  set ref_name [dbGet $inst_ptr.cell.name]
  set inst_name [dbGet $inst_ptr.name]

  if {[tier_is_split_buffer_name $ref_name] || [tier_is_split_buffer_name $inst_name]} {
    return "split_buffer"
  }

  if {[tier_is_upper_tag $ref_name] || [tier_is_upper_tag $inst_name]} {
    return "upper"
  }
  if {[tier_is_bottom_tag $ref_name] || [tier_is_bottom_tag $inst_name]} {
    return "bottom"
  }
  return "unknown"
}

proc tier_classify_inst_term_ptr {inst_term_ptr} {
  set inst_ptr [dbGet -e $inst_term_ptr.inst]
  return [tier_classify_inst_ptr $inst_ptr]
}

proc tier_classify_term_ptr {term_ptr} {
  if {$term_ptr eq "" || $term_ptr eq "0x0"} {
    return "unknown"
  }

  set has_upper 0
  set has_bottom 0
  foreach layer [tier_term_routing_layers $term_ptr] {
    set tier [tier_layer_to_tier $layer]
    if {$tier eq "upper"} {
      set has_upper 1
    } elseif {$tier eq "bottom"} {
      set has_bottom 1
    }
  }

  if {$has_upper && !$has_bottom} {
    return "upper"
  }
  if {$has_bottom && !$has_upper} {
    return "bottom"
  }
  return "unknown"
}

proc tier_classify_object_ptr {obj_ptr} {
  if {$obj_ptr eq "" || $obj_ptr eq "0x0"} {
    return "unknown"
  }

  set obj_type [dbGet $obj_ptr.objType]
  switch -- $obj_type {
    inst {
      return [tier_classify_inst_ptr $obj_ptr]
    }
    instTerm {
      return [tier_classify_inst_term_ptr $obj_ptr]
    }
    term {
      return [tier_classify_term_ptr $obj_ptr]
    }
    default {
      return "unknown"
    }
  }
}

proc tier_net_presence_counts {net_ptr} {
  lassign [tier_net_presence_detail_counts $net_ptr] upper_count bottom_count _ unknown_count
  return [list $upper_count $bottom_count $unknown_count]
}

proc tier_net_presence_detail_counts {net_ptr} {
  set upper_count 0
  set bottom_count 0
  set io_count 0
  set unknown_count 0

  foreach term [dbGet -e $net_ptr.terms] {
    incr io_count
    switch -- [tier_classify_term_ptr $term] {
      upper {
        incr upper_count
      }
      bottom {
        incr bottom_count
      }
      default {
        incr unknown_count
      }
    }
  }

  foreach inst_term [dbGet -e $net_ptr.instTerms] {
    switch -- [tier_classify_inst_term_ptr $inst_term] {
      upper {
        incr upper_count
      }
      bottom {
        incr bottom_count
      }
      split_buffer {
        # The split-net pass inserts a regular buffer interface between tiers.
        # Downstream tier-only optimization should classify the retained net by
        # the real retained sinks rather than by this synthetic relay pin.
        continue
      }
      default {
        incr unknown_count
      }
    }
  }

  return [list $upper_count $bottom_count $io_count $unknown_count]
}
