# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
#
# Create routing blockages on HB_layer while leaving periodic windows.
# The array is aligned to the HB_layer definition in the tech DB.
#
# Auto-derived values:
#   - region : from mL/mB/CORE_W/CORE_H in the caller flow
#   - pitch  : from layer pitchX/pitchY
#   - offset : from layer offsetX/offsetY
#   - window : from layer minWidth
#
# IMPORTANT:
#   In this Innovus version, createRouteBlk -box uses micron coordinates.

proc _hb_create_route_blk_if_valid {x0 y0 x1 y1 layer name} {
    if {$x1 <= $x0 || $y1 <= $y0} {
        return
    }

    createRouteBlk \
        -box [list $x0 $y0 $x1 $y1] \
        -layer $layer \
        -name $name
}

proc _hb_get_numeric_env_or_default {env_name default_value} {
    if {[info exists ::env($env_name)] && $::env($env_name) ne ""} {
        return [expr {double($::env($env_name))}]
    }
    return [expr {double($default_value)}]
}

proc _hb_resolve_layer_name {requested_layer} {
    set candidates [list $requested_layer [string tolower $requested_layer] [string toupper $requested_layer]]
    foreach candidate $candidates {
        set layer_ptr [dbGet -p head.layers.name $candidate]
        if {$layer_ptr ne "" && $layer_ptr ne "0x0"} {
            return [list $candidate $layer_ptr]
        }
    }
    return [list "" ""]
}

proc _hb_get_layer_geometry {requested_layer} {
    lassign [_hb_resolve_layer_name $requested_layer] resolved_layer layer_ptr
    if {$layer_ptr eq "" || $layer_ptr eq "0x0"} {
        error "create_hb_layer_obs: cannot find layer '$requested_layer'. Set TECH_LEF to a 3D tech LEF that defines the HBT routing layer."
    }

    set pitch_x  [expr {double([dbGet $layer_ptr.pitchX])}]
    set pitch_y  [expr {double([dbGet $layer_ptr.pitchY])}]
    set offset_x [expr {double([dbGet $layer_ptr.offsetX])}]
    set offset_y [expr {double([dbGet $layer_ptr.offsetY])}]
    set window_x [expr {double([dbGet $layer_ptr.minWidth])}]
    set window_y [expr {double([dbGet $layer_ptr.minWidth])}]

    return [list $resolved_layer $pitch_x $pitch_y $offset_x $offset_y $window_x $window_y]
}

proc hb_required_core_area {args} {
    array set opt {
        -layer HB_layer
        -estimated_hbt_count -1
        -util_limit ""
    }

    if {([llength $args] % 2) != 0} {
        error "hb_required_core_area: args must be key-value pairs, got: $args"
    }
    foreach {k v} $args {
        if {![info exists opt($k)]} {
            error "hb_required_core_area: unknown option $k"
        }
        set opt($k) $v
    }

    set estimated_hbt_count [expr {int($opt(-estimated_hbt_count))}]
    if {$estimated_hbt_count <= 0} {
        return 0.0
    }

    if {$opt(-util_limit) eq ""} {
        set util_limit [_hb_get_numeric_env_or_default HBT_MAX_CORE_UTILIZATION 0.8]
    } else {
        set util_limit [expr {double($opt(-util_limit))}]
    }
    if {$util_limit <= 0.0 || $util_limit > 1.0} {
        error "hb_required_core_area: util_limit must be in (0,1], got $util_limit"
    }

    lassign [_hb_get_layer_geometry $opt(-layer)] _ pitch_x pitch_y _ _ _ _
    return [expr {($pitch_x * $pitch_y * $estimated_hbt_count) / $util_limit}]
}

proc _hb_min_span_for_window_count {origin offset pitch half_window count} {
    if {$count <= 0} {
        return 0.0
    }
    set k_min [expr {int(ceil((($origin + $half_window) - $offset) / $pitch))}]
    set k_target [expr {$k_min + $count - 1}]
    return [expr {$offset + ($k_target * $pitch) + $half_window - $origin}]
}

proc hb_required_core_wh {args} {
    array set opt {
        -layer HB_layer
        -estimated_hbt_count -1
        -util_limit ""
        -aspect_ratio 1.0
        -origin_x 0.0
        -origin_y 0.0
    }

    if {([llength $args] % 2) != 0} {
        error "hb_required_core_wh: args must be key-value pairs, got: $args"
    }
    foreach {k v} $args {
        if {![info exists opt($k)]} {
            error "hb_required_core_wh: unknown option $k"
        }
        set opt($k) $v
    }

    set estimated_hbt_count [expr {int($opt(-estimated_hbt_count))}]
    if {$estimated_hbt_count <= 0} {
        return [list 0.0 0.0 0.0]
    }

    set aspect_ratio [expr {double($opt(-aspect_ratio))}]
    if {$aspect_ratio <= 0.0} {
        error "hb_required_core_wh: aspect_ratio must be > 0, got $aspect_ratio"
    }

    if {$opt(-util_limit) eq ""} {
        set util_limit [_hb_get_numeric_env_or_default HBT_MAX_CORE_UTILIZATION 0.8]
    } else {
        set util_limit [expr {double($opt(-util_limit))}]
    }
    if {$util_limit <= 0.0 || $util_limit > 1.0} {
        error "hb_required_core_wh: util_limit must be in (0,1], got $util_limit"
    }

    lassign [_hb_get_layer_geometry $opt(-layer)] _ pitch_x pitch_y offset_x offset_y window_x window_y

    set area_bound [expr {($pitch_x * $pitch_y * $estimated_hbt_count) / $util_limit}]
    set width_from_area [expr {sqrt($area_bound / $aspect_ratio)}]
    set half_wx [expr {$window_x / 2.0}]
    set half_wy [expr {$window_y / 2.0}]
    set best_w ""
    set best_h ""
    set best_area ""

    for {set nx 1} {$nx <= $estimated_hbt_count} {incr nx} {
        set ny [expr {int(ceil(double($estimated_hbt_count) / $nx))}]
        set min_wx [_hb_min_span_for_window_count $opt(-origin_x) $offset_x $pitch_x $half_wx $nx]
        set min_hy [_hb_min_span_for_window_count $opt(-origin_y) $offset_y $pitch_y $half_wy $ny]
        set width_needed [expr {max($width_from_area, $min_wx, $min_hy / $aspect_ratio)}]
        set height_needed [expr {$width_needed * $aspect_ratio}]
        set area_needed [expr {$width_needed * $height_needed}]
        if {$best_area eq "" || $area_needed < $best_area} {
            set best_w $width_needed
            set best_h $height_needed
            set best_area $area_needed
        }
    }

    return [list $best_w $best_h $best_area]
}

proc create_hb_layer_obs {args} {
    array set opt {
        -name_prefix HBOBS
        -layer       HB_layer
        -estimated_hbt_count -1
        -quiet       0
    }

    if {([llength $args] % 2) != 0} {
        error "create_hb_layer_obs: args must be key-value pairs, got: $args"
    }
    foreach {k v} $args {
        if {![info exists opt($k)]} {
            error "create_hb_layer_obs: unknown option $k"
        }
        set opt($k) $v
    }

    set layer  $opt(-layer)
    set prefix $opt(-name_prefix)
    set estimated_hbt_count [expr {int($opt(-estimated_hbt_count))}]
    set util_limit [_hb_get_numeric_env_or_default HBT_MAX_CORE_UTILIZATION 0.8]

    # ----------------------------------------
    # Auto region from the floorplan variables
    # ----------------------------------------
    foreach v {mL mB CORE_W CORE_H} {
        if {![info exists ::$v]} {
            error "create_hb_layer_obs: missing global variable ::$v for auto region"
        }
    }

    set rx0 $::mL
    set ry0 $::mB
    set rx1 [expr {$::mL + $::CORE_W}]
    set ry1 [expr {$::mB + $::CORE_H}]

    if {$rx1 <= $rx0 || $ry1 <= $ry0} {
        error "create_hb_layer_obs: invalid auto region {$rx0 $ry0 $rx1 $ry1}"
    }
    set core_area [expr {($rx1 - $rx0) * ($ry1 - $ry0)}]

    # ----------------------------------------
    # Auto pitch / offset / window from layer
    # ----------------------------------------
    lassign [_hb_get_layer_geometry $layer] layer pitch_x pitch_y offset_x offset_y window_x window_y

    if {$pitch_x <= 0.0 || $pitch_y <= 0.0} {
        error "create_hb_layer_obs: invalid pitch {$pitch_x $pitch_y} on layer $layer"
    }
    if {$window_x <= 0.0 || $window_y <= 0.0} {
        error "create_hb_layer_obs: invalid minWidth {$window_x $window_y} on layer $layer"
    }
    if {$window_x > $pitch_x || $window_y > $pitch_y} {
        error "create_hb_layer_obs: window must be <= pitch, got window={$window_x $window_y}, pitch={$pitch_x $pitch_y}"
    }

    if {$estimated_hbt_count > 0} {
        set estimated_hbt_area [expr {$pitch_x * $pitch_y * $estimated_hbt_count}]
        set max_hbt_area [expr {$core_area * $util_limit}]
        if {$estimated_hbt_area > $max_hbt_area} {
            error [format "create_hb_layer_obs: estimated HBT demand exceeds allowed core utilization (estimate=%d pitch_area=%.6f required_area=%.6f limit=%.6f util_limit=%.3f)" \
                $estimated_hbt_count [expr {$pitch_x * $pitch_y}] $estimated_hbt_area $max_hbt_area $util_limit]
        }
    }

    # ----------------------------------------
    # Compute legal window index range
    # Each legal window must be fully inside region
    # ----------------------------------------
    set half_wx [expr {$window_x / 2.0}]
    set half_wy [expr {$window_y / 2.0}]

    set kx_min [expr {int(ceil((($rx0 + $half_wx) - $offset_x) / $pitch_x))}]
    set kx_max [expr {int(floor((($rx1 - $half_wx) - $offset_x) / $pitch_x))}]
    set ky_min [expr {int(ceil((($ry0 + $half_wy) - $offset_y) / $pitch_y))}]
    set ky_max [expr {int(floor((($ry1 - $half_wy) - $offset_y) / $pitch_y))}]

    # ----------------------------------------
    # If no legal windows fit, block the whole region
    # This fixes the previous "return without coverage" bug.
    # ----------------------------------------
    if {$kx_max < $kx_min || $ky_max < $ky_min} {
        _hb_create_route_blk_if_valid \
            $rx0 $ry0 $rx1 $ry1 \
            $layer ${prefix}_FULL_0

        if {!$opt(-quiet)} {
            puts "WARN: No legal HB windows fit inside region {$rx0 $ry0 $rx1 $ry1}"
            puts "INFO: Blocked the entire region on layer $layer"
        }
        return
    }

    set num_windows_x [expr {$kx_max - $kx_min + 1}]
    set num_windows_y [expr {$ky_max - $ky_min + 1}]
    set max_window_count [expr {$num_windows_x * $num_windows_y}]
    if {$estimated_hbt_count > 0 && $estimated_hbt_count > $max_window_count} {
        error [format "create_hb_layer_obs: estimated HBT count exceeds legal HB windows (estimate=%d windows=%d)" \
            $estimated_hbt_count $max_window_count]
    }

    # ----------------------------------------
    # Precompute legal window spans
    # Coverage target:
    #   blockage union legal_windows == full CORE region
    # ----------------------------------------
    set row_spans {}
    for {set ky $ky_min} {$ky <= $ky_max} {incr ky} {
        set yc [expr {$offset_y + $ky * $pitch_y}]
        set row_y0 [expr {$yc - $half_wy}]
        set row_y1 [expr {$yc + $half_wy}]
        lappend row_spans [list $row_y0 $row_y1]
    }

    set col_spans {}
    for {set kx $kx_min} {$kx <= $kx_max} {incr kx} {
        set xc [expr {$offset_x + $kx * $pitch_x}]
        set col_x0 [expr {$xc - $half_wx}]
        set col_x1 [expr {$xc + $half_wx}]
        lappend col_spans [list $col_x0 $col_x1]
    }

    set blk_idx 0

    # ----------------------------------------
    # 1) Block full-width strips outside legal window rows
    # This covers:
    #   - bottom edge gap
    #   - top edge gap
    #   - pitch rows without legal windows
    # ----------------------------------------
    set prev_y $ry0
    foreach row $row_spans {
        lassign $row row_y0 row_y1

        _hb_create_route_blk_if_valid \
            $rx0 $prev_y $rx1 $row_y0 \
            $layer ${prefix}_H_${blk_idx}
        incr blk_idx

        set prev_y $row_y1
    }

    _hb_create_route_blk_if_valid \
        $rx0 $prev_y $rx1 $ry1 \
        $layer ${prefix}_H_${blk_idx}
    incr blk_idx

    # ----------------------------------------
    # 2) For each legal row, block everything except legal windows
    # This covers:
    #   - left edge gap
    #   - right edge gap
    #   - gaps between adjacent legal windows
    # ----------------------------------------
    foreach row $row_spans {
        lassign $row row_y0 row_y1

        set prev_x $rx0
        foreach col $col_spans {
            lassign $col col_x0 col_x1

            _hb_create_route_blk_if_valid \
                $prev_x $row_y0 $col_x0 $row_y1 \
                $layer ${prefix}_R_${blk_idx}
            incr blk_idx

            set prev_x $col_x1
        }

        _hb_create_route_blk_if_valid \
            $prev_x $row_y0 $rx1 $row_y1 \
            $layer ${prefix}_R_${blk_idx}
        incr blk_idx
    }

    if {!$opt(-quiet)} {
        puts "INFO: Created HB_layer routing obstructions on layer $layer"
        puts "INFO: Region     = {$rx0 $ry0 $rx1 $ry1}"
        puts "INFO: Pitch      = {$pitch_x $pitch_y}"
        puts "INFO: Window     = {$window_x $window_y}"
        puts "INFO: Offset     = {$offset_x $offset_y}"
        puts "INFO: NumWindows = $max_window_count"
        puts "INFO: NumBlockages = $blk_idx"
        if {$estimated_hbt_count > 0} {
            puts "INFO: Estimated HBT Count = $estimated_hbt_count"
            puts "INFO: HBT Core Util Limit = $util_limit"
        }
    }
}

proc delete_hb_layer_obs {name_prefix} {
    foreach blk [dbGet top.fPlan.rBlkgs.name] {
        if {[string match "${name_prefix}*" $blk]} {
            deleteRouteBlk -name $blk
        }
    }
}
