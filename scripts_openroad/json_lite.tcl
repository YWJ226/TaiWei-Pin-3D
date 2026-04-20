#
# json_lite.tcl
# A tiny JSON parser plus a few generic Tcl helpers that are reused by
# flow scripts consuming structured config files.
#

namespace eval ::json_lite {
  variable text ""
  variable idx 0
}

proc ::json_lite::parse_file {path} {
  set fh [open $path r]
  set data [read $fh]
  close $fh
  return [::json_lite::parse $data]
}

proc ::json_lite::parse {data} {
  variable text
  variable idx
  set text $data
  set idx 0
  set value [::json_lite::_parse_value]
  ::json_lite::_skip_ws
  if {$idx != [string length $text]} {
    error "json parse error at index $idx: trailing content"
  }
  return $value
}

proc ::json_lite::dict_get_default {d key default} {
  if {[catch {dict get $d $key} value]} {
    return $default
  }
  return $value
}

proc ::json_lite::dict_exists_path {d args} {
  return [expr {![catch {dict get $d {*}$args}]}]
}

proc ::json_lite::try_double {value default} {
  if {[string is double -strict $value]} {
    return [expr {double($value)}]
  }
  return $default
}

proc ::json_lite::_peek {} {
  variable text
  variable idx
  return [string index $text $idx]
}

proc ::json_lite::_advance {{count 1}} {
  variable idx
  incr idx $count
}

proc ::json_lite::_skip_ws {} {
  variable text
  variable idx
  set n [string length $text]
  while {$idx < $n} {
    set ch [string index $text $idx]
    if {$ch ni {" " "\t" "\n" "\r"}} {
      break
    }
    incr idx
  }
}

proc ::json_lite::_expect {char} {
  set got [::json_lite::_peek]
  if {$got ne $char} {
    error "json parse error: expected '$char', got '$got'"
  }
  ::json_lite::_advance
}

proc ::json_lite::_parse_value {} {
  variable text
  variable idx
  ::json_lite::_skip_ws
  if {$idx >= [string length $text]} {
    error "json parse error: unexpected end of input"
  }
  set ch [::json_lite::_peek]
  switch -exact -- $ch {
    "\{" { return [::json_lite::_parse_object] }
    "[" { return [::json_lite::_parse_array] }
    "\"" { return [::json_lite::_parse_string] }
    "t" {
      if {[string range $text $idx [expr {$idx + 3}]] ne "true"} {
        error "json parse error: invalid token near index $idx"
      }
      ::json_lite::_advance 4
      return true
    }
    "f" {
      if {[string range $text $idx [expr {$idx + 4}]] ne "false"} {
        error "json parse error: invalid token near index $idx"
      }
      ::json_lite::_advance 5
      return false
    }
    "n" {
      if {[string range $text $idx [expr {$idx + 3}]] ne "null"} {
        error "json parse error: invalid token near index $idx"
      }
      ::json_lite::_advance 4
      return null
    }
    default {
      if {$ch eq "-" || [string is digit -strict $ch]} {
        return [::json_lite::_parse_number]
      }
      error "json parse error: unexpected character '$ch' at index $idx"
    }
  }
}

proc ::json_lite::_parse_object {} {
  set result [dict create]
  ::json_lite::_expect "\{"
  ::json_lite::_skip_ws
  if {[::json_lite::_peek] eq "\}"} {
    ::json_lite::_advance
    return $result
  }
  while {1} {
    ::json_lite::_skip_ws
    set key [::json_lite::_parse_string]
    ::json_lite::_skip_ws
    ::json_lite::_expect ":"
    set value [::json_lite::_parse_value]
    dict set result $key $value
    ::json_lite::_skip_ws
    set sep [::json_lite::_peek]
    if {$sep eq "\}"} {
      ::json_lite::_advance
      break
    }
    if {$sep ne ","} {
      error "json parse error: expected ',' or '\}', got '$sep'"
    }
    ::json_lite::_advance
  }
  return $result
}

proc ::json_lite::_parse_array {} {
  set result {}
  ::json_lite::_expect "\["
  ::json_lite::_skip_ws
  if {[::json_lite::_peek] eq {]}} {
    ::json_lite::_advance
    return $result
  }
  while {1} {
    lappend result [::json_lite::_parse_value]
    ::json_lite::_skip_ws
    set sep [::json_lite::_peek]
    if {$sep eq {]}} {
      ::json_lite::_advance
      break
    }
    if {$sep ne ","} {
      error "json parse error: expected ',' or '\]', got '$sep'"
    }
    ::json_lite::_advance
  }
  return $result
}

proc ::json_lite::_parse_string {} {
  variable text
  variable idx
  ::json_lite::_expect "\""
  set out ""
  set n [string length $text]
  while {$idx < $n} {
    set ch [string index $text $idx]
    incr idx
    if {$ch eq "\""} {
      return $out
    }
    if {$ch ne "\\"} {
      append out $ch
      continue
    }
    if {$idx >= $n} {
      error "json parse error: dangling escape"
    }
    set esc [string index $text $idx]
    incr idx
    switch -exact -- $esc {
      "\"" { append out "\"" }
      "\\" { append out "\\" }
      "/"  { append out "/" }
      "b"  { append out "\b" }
      "f"  { append out "\f" }
      "n"  { append out "\n" }
      "r"  { append out "\r" }
      "t"  { append out "\t" }
      "u"  {
        if {$idx + 3 >= $n} {
          error "json parse error: short unicode escape"
        }
        set hex [string range $text $idx [expr {$idx + 3}]]
        if {![regexp {^[0-9A-Fa-f]{4}$} $hex]} {
          error "json parse error: invalid unicode escape '$hex'"
        }
        scan $hex %x codepoint
        append out [format %c $codepoint]
        incr idx 4
      }
      default {
        error "json parse error: unsupported escape '\\$esc'"
      }
    }
  }
  error "json parse error: unterminated string"
}

proc ::json_lite::_parse_number {} {
  variable text
  variable idx
  set rest [string range $text $idx end]
  if {![regexp {^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?} $rest token]} {
    error "json parse error: invalid number near index $idx"
  }
  incr idx [string length $token]
  return $token
}
