#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import json
import os
import re
from typing import Dict, List, Tuple, Optional

# ------------------------------------------------------------
# Name normalization helpers (DEF / Verilog / partition shared)
# ------------------------------------------------------------
def normalize_name(s: str) -> str:
    """
    Normalize instance/net/pin identifiers across DEF / Verilog / partition:
      - Strip leading/trailing whitespace
      - Remove leading escape backslash (Verilog escaped identifiers)
      - Unescape DEF-style bracket escapes: '\\[' -> '[', '\\]' -> ']'
    """
    t = s.strip()
    if t.startswith("\\"):
        # Verilog escaped identifier: \name_with_stuff<space>
        t = t[1:]
    t = t.replace("\\[", "[").replace("\\]", "]")
    return t

def normalize_from_def(tok: str) -> str:
    return normalize_name(tok)

def normalize_from_verilog(tok: str) -> str:
    return normalize_name(tok)

def strip_tier_suffix(master: str) -> str:
    if master.endswith("_upper"):
        return master[:-6]
    if master.endswith("_bottom"):
        return master[:-7]
    return master

def swap_partition_labels(part_map: Dict[str, int]) -> Dict[str, int]:
    return {k: (1 - v) if v in (0, 1) else v for k, v in part_map.items()}

def _try_float(val) -> Optional[float]:
    try:
        return float(val)
    except (TypeError, ValueError):
        return None

def _require_dict(value, context: str) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"cell map format error: '{context}' must be a dict.")
    return value

def _require_str(value, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"cell map format error: '{context}' must be a non-empty string.")
    return value

def _require_pin_map(value, context: str) -> Dict[str, str]:
    mapping = _require_dict(value, context)
    out: Dict[str, str] = {}
    for src, dst in mapping.items():
        if not isinstance(src, str) or not isinstance(dst, str) or not src or not dst:
            raise ValueError(f"cell map format error: '{context}' entries must be non-empty strings.")
        out[src] = dst
    return out

def _parse_const_pins(value, context: str) -> Dict[str, str]:
    if value is None:
        return {}
    mapping = _require_dict(value, context)
    out: Dict[str, str] = {}
    for pin, const_value in mapping.items():
        if not isinstance(pin, str) or not pin:
            raise ValueError(f"cell map format error: '{context}' pins must be non-empty strings.")
        if not isinstance(const_value, str) or not const_value:
            raise ValueError(f"cell map format error: '{context}.{pin}' must be a non-empty string.")
        out[pin] = const_value
    return out

def _tier_name(die: int) -> str:
    if die == 0:
        return "upper"
    if die == 1:
        return "bottom"
    raise ValueError(f"invalid die label {die!r}; expected 0 or 1")

def _tier_pin_map(
    die: int,
    base: str,
    base_to_bottom_pin_map: Dict[str, Dict[str, str]],
    base_to_upper_pin_map: Dict[str, Dict[str, str]],
) -> Dict[str, str]:
    table = base_to_upper_pin_map if die == 0 else base_to_bottom_pin_map
    tier = _tier_name(die)
    if base not in table:
        raise ValueError(f"cell map missing {tier}.pin_map for base cell '{base}'.")
    return table[base]

def _tier_const_pins(
    die: int,
    base: str,
    base_to_bottom_const_pins: Dict[str, Dict[str, str]],
    base_to_upper_const_pins: Dict[str, Dict[str, str]],
) -> Dict[str, str]:
    table = base_to_upper_const_pins if die == 0 else base_to_bottom_const_pins
    return table.get(base, {})

def _map_pin_name(pin_map: Dict[str, str], pin: str) -> Optional[str]:
    if pin in pin_map:
        return pin_map[pin]
    bus_match = re.match(r"^(.+)(\[[^\]]+\])$", pin)
    if bus_match and bus_match.group(1) in pin_map:
        return pin_map[bus_match.group(1)] + bus_match.group(2)
    return None

# ------------------------------------------------------------
# Partition file parsing
# ------------------------------------------------------------
def parse_partition_file(partition_path: Optional[str]) -> Dict[str, int]:
    """
    Reads partition file lines in common formats:
      - "<inst> <die>"
      - "<inst> ... <die>"  (die is last token, 0/1)
    Ignores empty/comments (#, //).
    """
    part: Dict[str, int] = {}
    if not partition_path:
        return part
    if not os.path.exists(partition_path):
        print(f"[WARN] partition file '{partition_path}' not found, ignored.")
        return part

    with open(partition_path, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#") or line.startswith("//"):
                continue
            toks = line.split()
            if len(toks) < 2:
                continue
            inst = toks[0]
            die_s = toks[-1]
            if die_s not in ("0", "1"):
                continue
            die = int(die_s)
            part[normalize_name(inst)] = die
    return part

# ------------------------------------------------------------
# DEF parsing helpers
# ------------------------------------------------------------
COMP_BEGIN_RE = re.compile(r"^\s*COMPONENTS\b", re.I)
COMP_END_RE   = re.compile(r"^\s*END\s+COMPONENTS\b", re.I)
NETS_BEGIN_RE = re.compile(r"^\s*NETS\b", re.I)
NETS_END_RE   = re.compile(r"^\s*END\s+NETS\b", re.I)
PINS_BEGIN_RE = re.compile(r"^\s*PINS\b", re.I)
PINS_END_RE   = re.compile(r"^\s*END\s+PINS\b", re.I)

# DEF component first line:
#   - <inst> <master> ...
COMP_FIRST_RE = re.compile(r"^(\s*)-\s+(\S+)\s+(\S+)(.*)$")
PIN_FIRST_RE = re.compile(r"^\s*-\s+(\S+)")

# DEF NET connection tuple: ( inst pin ) or ( PIN xxx ) or ( 123 456 ) etc.
DEF_CONN_RE = re.compile(r"\(\s*(\S+)\s+(\S+)\s*\)")

def collect_inst_base_from_def(def_path: str) -> Dict[str, str]:
    """
    Collect inst -> base master from DEF COMPONENTS.
    Handles multi-line components; only parses the leading "- inst master" line.
    """
    inst2base: Dict[str, str] = {}
    try:
        lines = open(def_path, "r", encoding="utf-8", errors="ignore").readlines()
    except FileNotFoundError:
        print(f"[ERROR] DEF file '{def_path}' not found for collect_inst_base_from_def.")
        return inst2base

    in_comp = False
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if not in_comp and COMP_BEGIN_RE.match(line):
            in_comp = True
            i += 1
            continue
        if in_comp and COMP_END_RE.match(line):
            in_comp = False
            i += 1
            continue

        if in_comp:
            m = COMP_FIRST_RE.match(line)
            if m:
                _, inst_raw, master, _ = m.groups()
                inst_norm = normalize_from_def(inst_raw)
                inst2base[inst_norm] = strip_tier_suffix(master)

                # Skip to end of this component (until ';')
                if ";" in line:
                    i += 1
                else:
                    i += 1
                    while i < n and ";" not in lines[i]:
                        i += 1
                    if i < n:
                        i += 1
                continue
        i += 1

    return inst2base

def collect_top_pins_from_def(def_path: str) -> List[str]:
    """
    Collect top-level pin names from DEF PINS section.
    """
    pin_names: List[str] = []
    try:
        lines = open(def_path, "r", encoding="utf-8", errors="ignore").readlines()
    except FileNotFoundError:
        print(f"[ERROR] DEF file '{def_path}' not found for collect_top_pins_from_def.")
        return pin_names

    in_pins = False
    for line in lines:
        if not in_pins and PINS_BEGIN_RE.match(line):
            in_pins = True
            continue
        if in_pins and PINS_END_RE.match(line):
            break
        if in_pins:
            m = PIN_FIRST_RE.match(line)
            if m:
                pin_names.append(normalize_from_def(m.group(1)))

    return pin_names

def rewrite_def_net_block(
    net_lines: List[str],
    part_map: Dict[str, int],
    inst2base: Dict[str, str],
    base_to_bottom_pin_map: Dict[str, Dict[str, str]],
    base_to_upper_pin_map: Dict[str, Dict[str, str]],
    has_cell_map: bool,
) -> List[str]:
    """
    Rewrite one DEF net block (from '-' to terminating ';'):
      - Rewrite ( inst pin ) tuples using the target tier pin_map.
      - Leave ( PIN xxx ) alone.
      - Leave coordinates ( x y ) alone because inst not in part_map.
    """
    if not has_cell_map:
        return net_lines

    text = "".join(net_lines)
    errors: List[str] = []

    def repl(m) -> str:
        inst = m.group(1)
        pin  = m.group(2)

        if inst == "PIN":
            return m.group(0)

        inst_norm = normalize_name(inst)
        die = part_map.get(inst_norm)
        base = inst2base.get(inst_norm)

        if die is None or base is None:
            return m.group(0)

        try:
            pm = _tier_pin_map(die, base, base_to_bottom_pin_map, base_to_upper_pin_map)
        except ValueError as exc:
            errors.append(str(exc))
            return m.group(0)

        new_pin = _map_pin_name(pm, pin)
        if new_pin is None:
            errors.append(
                f"cell map missing {_tier_name(die)} pin mapping for base cell '{base}' pin '{pin}'"
                f" on DEF instance '{inst}'"
            )
            return m.group(0)

        return f"( {inst} {new_pin} )"

    new_text = DEF_CONN_RE.sub(repl, text)
    if errors:
        raise ValueError("; ".join(errors))
    return new_text.splitlines(keepends=True)

def rewrite_def(
    def_in: str,
    def_out: str,
    part_map: Dict[str, int],
    base_to_bottom: Dict[str, str],
    base_to_upper: Dict[str, str],
    base_to_bottom_pin_map: Dict[str, Dict[str, str]],
    base_to_upper_pin_map: Dict[str, Dict[str, str]],
    has_cell_map: bool,
) -> None:
    """
    Rewrite DEF:
      - COMPONENTS: update master per inst->die using JSON macro mapping if available
      - NETS: remap pins using the target tier pin_map
    """
    try:
        lines = open(def_in, "r", encoding="utf-8", errors="ignore").readlines()
    except FileNotFoundError:
        print(f"[ERROR] DEF file '{def_in}' not found.")
        return

    inst2base = collect_inst_base_from_def(def_in)

    out: List[str] = []
    in_comp = False
    in_nets = False
    i, n = 0, len(lines)

    while i < n:
        line = lines[i]

        # COMPONENTS begin/end
        if not in_comp and COMP_BEGIN_RE.match(line):
            in_comp = True
            out.append(line)
            i += 1
            continue
        if in_comp and COMP_END_RE.match(line):
            in_comp = False
            out.append(line)
            i += 1
            continue

        if in_comp:
            m = COMP_FIRST_RE.match(line)
            if m:
                indent, inst_raw, master, rest = m.groups()
                inst_key = normalize_from_def(inst_raw)
                die = part_map.get(inst_key)

                new_master = master
                if die is not None:
                    base = strip_tier_suffix(master)
                    if not has_cell_map:
                        new_master = base + ("_upper" if die == 0 else "_bottom")
                    elif die == 0 and base in base_to_upper:
                        new_master = base_to_upper[base]
                    elif die == 1 and base in base_to_bottom:
                        new_master = base_to_bottom[base]
                    else:
                        raise ValueError(f"cell map missing {_tier_name(die)}.macro for base cell '{base}'")

                out.append(f"{indent}- {inst_raw} {new_master}{rest}\n")

                # Copy rest of component until ';'
                if ";" in line:
                    i += 1
                else:
                    i += 1
                    while i < n:
                        out.append(lines[i])
                        if ";" in lines[i]:
                            i += 1
                            break
                        i += 1
                continue

            out.append(line)
            i += 1
            continue

        # NETS begin/end
        if not in_nets and NETS_BEGIN_RE.match(line):
            in_nets = True
            out.append(line)
            i += 1
            continue
        if in_nets and NETS_END_RE.match(line):
            in_nets = False
            out.append(line)
            i += 1
            continue

        if in_nets:
            stripped = line.lstrip()
            if stripped.startswith("-"):
                buf = [line]
                i += 1
                while i < n:
                    buf.append(lines[i])
                    if ";" in lines[i]:
                        i += 1
                        break
                    i += 1
                new_block = rewrite_def_net_block(
                    buf,
                    part_map,
                    inst2base,
                    base_to_bottom_pin_map,
                    base_to_upper_pin_map,
                    has_cell_map,
                )
                out.extend(new_block)
                continue
            out.append(line)
            i += 1
            continue

        out.append(line)
        i += 1

    with open(def_out, "w", encoding="utf-8") as f:
        f.writelines(out)

# ------------------------------------------------------------
# Verilog robust instance statement scanning + comment masking
# ------------------------------------------------------------
def mask_verilog_comments_keep_len(s: str) -> str:
    """
    Replace comment characters with spaces, preserving string length.
    Handles:
      - // ... \n
      - /* ... */
    This allows regex span indices to apply to original text.
    """
    out = list(s)
    i = 0
    n = len(out)
    while i < n:
        if i + 1 < n and out[i] == "/" and out[i+1] == "/":
            # line comment
            j = i
            while j < n and out[j] != "\n":
                out[j] = " "
                j += 1
            i = j
            continue
        if i + 1 < n and out[i] == "/" and out[i+1] == "*":
            # block comment
            j = i
            out[j] = " "
            out[j+1] = " "
            j += 2
            while j + 1 < n and not (out[j] == "*" and out[j+1] == "/"):
                out[j] = " "
                j += 1
            if j + 1 < n:
                out[j] = " "
                out[j+1] = " "
                j += 2
            i = j
            continue
        i += 1
    return "".join(out)

def split_verilog_statements(text: str) -> List[Tuple[int, int]]:
    """
    Split Verilog into top-level statements by ';' while tracking parentheses depth and strings.
    Returns list of (start,end) spans in the original text (end includes ';').
    """
    spans: List[Tuple[int, int]] = []
    depth = 0
    in_str = False
    esc = False
    start = 0
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue

        if c == '"':
            in_str = True
            i += 1
            continue

        if c == "(":
            depth += 1
        elif c == ")":
            if depth > 0:
                depth -= 1
        elif c == ";" and depth == 0:
            spans.append((start, i + 1))
            start = i + 1
        i += 1

    if start < n:
        spans.append((start, n))
    return spans

# instance header matcher (operates on COMMENT-MASKED text so spans align)
# module can be normal or escaped; instance can be normal or escaped
VERILOG_INST_HDR_RE = re.compile(
    r"""^(\s*)                                  # 1 indent
         ((?:\\\S+)|(?:[A-Za-z_][\w$]*))         # 2 module token
         (\s*)                                   # 3 ws
         (?:\#\s*\(.*?\)\s*)?                    # optional params
         ((?:\\\S+)|(?:[A-Za-z_][\w$]*))         # 4 instance token
         \s*\(                                   # '('
    """,
    re.VERBOSE | re.S
)

VERILOG_PORT_RE = re.compile(r"(\.\s*)([A-Za-z_][\w$]*)(\s*\()")

def _append_const_ports_instance(stmt: str, const_pins: Dict[str, str]) -> str:
    """
    Append .PIN(CONST) bindings for missing pins before the last ');' in stmt.
    """
    if not const_pins:
        return stmt

    existing = {m.group(2) for m in VERILOG_PORT_RE.finditer(stmt)}
    missing = [(p, const_pins[p]) for p in const_pins if p not in existing]
    if not missing:
        return stmt

    k = stmt.rfind(");")
    if k < 0:
        return stmt

    # indent: use indentation of last port line if present; else use two spaces
    prefix = stmt[:k]
    lines = prefix.splitlines()
    indent = "  "
    if lines:
        m = re.match(r"(\s*)", lines[-1])
        if m:
            indent = m.group(1)

    ins = ""
    for p, value in missing:
        ins += f",\n{indent}.{p}({value})"
    return stmt[:k] + ins + stmt[k:]

def parse_cell_map_json(cell_map_path: Optional[str]):
    base_to_bottom: Dict[str, str] = {}
    base_to_upper: Dict[str, str] = {}
    base_to_bottom_pin_map: Dict[str, Dict[str, str]] = {}
    base_to_upper_pin_map: Dict[str, Dict[str, str]] = {}
    base_to_bottom_const_pins: Dict[str, Dict[str, str]] = {}
    base_to_upper_const_pins: Dict[str, Dict[str, str]] = {}
    base_to_tier_areas: Dict[str, Tuple[float, float]] = {}
    has_heterogeneous_area_map = False
    has_cell_map = False

    if not cell_map_path:
        return (
            base_to_bottom,
            base_to_upper,
            base_to_bottom_pin_map,
            base_to_upper_pin_map,
            base_to_bottom_const_pins,
            base_to_upper_const_pins,
            base_to_tier_areas,
            has_heterogeneous_area_map,
            has_cell_map,
        )
    if not os.path.exists(cell_map_path):
        print(f"[WARN] cell map JSON '{cell_map_path}' not found, use suffix-based homogeneous mapping.")
        return (
            base_to_bottom,
            base_to_upper,
            base_to_bottom_pin_map,
            base_to_upper_pin_map,
            base_to_bottom_const_pins,
            base_to_upper_const_pins,
            base_to_tier_areas,
            has_heterogeneous_area_map,
            has_cell_map,
        )

    with open(cell_map_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    cells = data.get("cells", {})
    if not isinstance(cells, dict):
        raise ValueError("cell map JSON format error: 'cells' must be a dict.")
    has_cell_map = True

    for key, cell in cells.items():
        if not isinstance(cell, dict):
            raise ValueError(f"cell map format error: cells.{key} must be a dict.")

        base_cfg = _require_dict(cell.get("base"), f"cells.{key}.base")
        bottom = _require_dict(cell.get("bottom"), f"cells.{key}.bottom")
        upper = _require_dict(cell.get("upper"), f"cells.{key}.upper")

        base = _require_str(base_cfg.get("macro"), f"cells.{key}.base.macro")
        base_to_bottom[base] = _require_str(bottom.get("macro"), f"cells.{key}.bottom.macro")
        base_to_upper[base] = _require_str(upper.get("macro"), f"cells.{key}.upper.macro")
        base_to_bottom_pin_map[base] = _require_pin_map(
            bottom.get("pin_map"), f"cells.{key}.bottom.pin_map"
        )
        base_to_upper_pin_map[base] = _require_pin_map(
            upper.get("pin_map"), f"cells.{key}.upper.pin_map"
        )

        bottom_const = _parse_const_pins(bottom.get("const_pins"), f"cells.{key}.bottom.const_pins")
        if bottom_const:
            base_to_bottom_const_pins[base] = bottom_const
        upper_const = _parse_const_pins(upper.get("const_pins"), f"cells.{key}.upper.const_pins")
        if upper_const:
            base_to_upper_const_pins[base] = upper_const

        bw = _try_float(bottom.get("width"))
        bh = _try_float(bottom.get("height"))
        uw = _try_float(upper.get("width"))
        uh = _try_float(upper.get("height"))
        if None not in (bw, bh, uw, uh):
            bottom_area = bw * bh
            upper_area = uw * uh
            base_to_tier_areas[base] = (bottom_area, upper_area)

            bottom_macro = bottom.get("macro")
            upper_macro = upper.get("macro")
            if bottom_macro != upper_macro or abs(bottom_area - upper_area) > 1.0e-12:
                has_heterogeneous_area_map = True

    return (
        base_to_bottom,
        base_to_upper,
        base_to_bottom_pin_map,
        base_to_upper_pin_map,
        base_to_bottom_const_pins,
        base_to_upper_const_pins,
        base_to_tier_areas,
        has_heterogeneous_area_map,
        has_cell_map,
    )

def rewrite_verilog(
    v_in: str,
    v_out: str,
    part_map: Dict[str, int],
    base_to_bottom: Dict[str, str],
    base_to_upper: Dict[str, str],
    base_to_bottom_pin_map: Dict[str, Dict[str, str]],
    base_to_upper_pin_map: Dict[str, Dict[str, str]],
    base_to_bottom_const_pins: Dict[str, Dict[str, str]],
    base_to_upper_const_pins: Dict[str, Dict[str, str]],
    has_cell_map: bool,
) -> None:
    """
    Robust rewrite for structural/gate-level Verilog instance statements.
    Works on full-file statement spans. Uses comment masking so indices align.

      - Rename module based on inst->die and JSON macro mapping
      - Rename ports using the target tier pin_map
      - Bind explicit const_pins when requested by map.json
    """
    try:
        text = open(v_in, "r", encoding="utf-8", errors="ignore").read()
    except FileNotFoundError:
        print(f"[ERROR] Verilog file '{v_in}' not found.")
        return

    masked = mask_verilog_comments_keep_len(text)
    spans = split_verilog_statements(text)

    out_chunks: List[str] = []
    last = 0

    for (a, b) in spans:
        stmt = text[a:b]
        stmt_m = masked[a:b]

        out_chunks.append(text[last:a])
        last = b

        # Quick filter: instance statements usually contain '(' and ')'
        if "(" not in stmt_m:
            out_chunks.append(stmt)
            continue

        m = VERILOG_INST_HDR_RE.match(stmt_m)
        if not m:
            out_chunks.append(stmt)
            continue

        indent = m.group(1)
        module_tok = m.group(2)
        inst_tok   = m.group(4)

        inst_norm = normalize_from_verilog(inst_tok)
        die = part_map.get(inst_norm)
        if die is None:
            out_chunks.append(stmt)
            continue

        module_base = strip_tier_suffix(module_tok)

        if not has_cell_map:
            new_module = module_base + ("_upper" if die == 0 else "_bottom")
        elif die == 0 and module_base in base_to_upper:
            new_module = base_to_upper[module_base]
        elif die == 1 and module_base in base_to_bottom:
            new_module = base_to_bottom[module_base]
        else:
            raise ValueError(f"cell map missing {_tier_name(die)}.macro for base cell '{module_base}'")

        # Replace module token at the exact span in original stmt (based on masked match)
        mod_span = m.span(2)  # (start,end) inside stmt
        stmt2 = stmt[:mod_span[0]] + new_module + stmt[mod_span[1]:]
        port_start = m.end() + (len(new_module) - len(module_tok))

        if has_cell_map:
            pm = _tier_pin_map(die, module_base, base_to_bottom_pin_map, base_to_upper_pin_map)

            def _port_repl(mm):
                dot, pin, lp = mm.groups()
                new_pin = _map_pin_name(pm, pin)
                if new_pin is None:
                    raise ValueError(
                        f"cell map missing {_tier_name(die)} pin mapping for base cell "
                        f"'{module_base}' pin '{pin}' on Verilog instance '{inst_norm}'"
                )
                return f"{dot}{new_pin}{lp}"

            stmt2 = stmt2[:port_start] + VERILOG_PORT_RE.sub(_port_repl, stmt2[port_start:])

            const_pins = _tier_const_pins(
                die,
                module_base,
                base_to_bottom_const_pins,
                base_to_upper_const_pins,
            )
            stmt2 = _append_const_ports_instance(stmt2, const_pins)

        out_chunks.append(stmt2)

    out_chunks.append(text[last:])

    with open(v_out, "w", encoding="utf-8") as f:
        f.write("".join(out_chunks))

def choose_partition_orientation_by_area(
    part_map: Dict[str, int],
    def_path: str,
    base_to_tier_areas: Dict[str, Tuple[float, float]],
    has_heterogeneous_area_map: bool,
) -> Dict[str, int]:
    """
    For heterogeneous platforms, choose whether partition label 0 or 1 should map
    to the upper tier based on mapped cell areas from map.json.
    """
    if not part_map:
        return part_map

    if not has_heterogeneous_area_map or not base_to_tier_areas:
        print("[INFO] Keep original partition labels: no usable heterogeneous map-based area data.")
        return part_map

    inst2base = collect_inst_base_from_def(def_path)
    if not inst2base:
        print("[INFO] Keep original partition labels: cannot collect instance masters from DEF for area estimation.")
        return part_map

    original_upper_area = 0.0
    original_bottom_area = 0.0
    swapped_upper_area = 0.0
    swapped_bottom_area = 0.0
    mapped_count = 0
    skipped_count = 0

    for inst_name, die in part_map.items():
        if die not in (0, 1):
            skipped_count += 1
            continue

        base = inst2base.get(inst_name)
        if base is None:
            skipped_count += 1
            continue

        tier_areas = base_to_tier_areas.get(base)
        if tier_areas is None:
            skipped_count += 1
            continue

        bottom_area, upper_area = tier_areas
        mapped_count += 1

        if die == 0:
            original_upper_area += upper_area
            swapped_bottom_area += bottom_area
        else:
            original_bottom_area += bottom_area
            swapped_upper_area += upper_area

    if mapped_count == 0:
        print("[INFO] Keep original partition labels: no instances matched usable map-based area data.")
        return part_map

    original_max_area = max(original_upper_area, original_bottom_area)
    swapped_max_area = max(swapped_upper_area, swapped_bottom_area)
    print(
        "[INFO] Partition orientation area estimate: "
        f"mapped={mapped_count} skipped={skipped_count}; "
        f"original upper={original_upper_area:.6f} bottom={original_bottom_area:.6f} max={original_max_area:.6f}; "
        f"swapped upper={swapped_upper_area:.6f} bottom={swapped_bottom_area:.6f} max={swapped_max_area:.6f}"
    )

    if swapped_max_area + 1.0e-12 < original_max_area:
        print("[INFO] Selected swapped partition orientation: label 0 -> bottom, label 1 -> upper.")
        return swap_partition_labels(part_map)

    print("[INFO] Selected original partition orientation: label 0 -> upper, label 1 -> bottom.")
    return part_map

def choose_partition_orientation_by_pins(
    part_map: Dict[str, int],
    def_path: str,
) -> Dict[str, int]:
    """
    For homogeneous platforms, use the top-level pin assignments in partition.txt
    to place the pin-heavier cluster on the bottom tier.
    """
    if not part_map:
        return part_map

    top_pins = set(collect_top_pins_from_def(def_path))
    if not top_pins:
        print("[INFO] Keep original partition labels: no DEF top-level pins found for homogeneous pin-based orientation.")
        return part_map

    pin_count_0 = 0
    pin_count_1 = 0
    skipped_count = 0

    for name, die in part_map.items():
        if name not in top_pins:
            continue
        if die == 0:
            pin_count_0 += 1
        elif die == 1:
            pin_count_1 += 1
        else:
            skipped_count += 1

    total_pins = pin_count_0 + pin_count_1
    if total_pins == 0:
        print("[INFO] Keep original partition labels: no partitioned top-level pins matched DEF PINS.")
        return part_map

    print(
        "[INFO] Homogeneous pin-based orientation estimate: "
        f"partition0_pins={pin_count_0} partition1_pins={pin_count_1} skipped={skipped_count}"
    )

    if pin_count_0 > pin_count_1:
        print("[INFO] Selected swapped partition orientation: pin-heavier cluster moved to bottom tier.")
        return swap_partition_labels(part_map)

    if pin_count_1 > pin_count_0:
        print("[INFO] Selected original partition orientation: pin-heavier cluster already on bottom tier.")
        return part_map

    print("[INFO] Keep original partition labels: homogeneous pin counts tie.")
    return part_map

def main():
    ap = argparse.ArgumentParser(
        description="Convert 2D DEF/Verilog to 3D tier views using partition + JSON cell map."
    )
    ap.add_argument("--def-in", required=True)
    ap.add_argument("--def-out", required=True)
    ap.add_argument("--v-in", required=True)
    ap.add_argument("--v-out", required=True)
    ap.add_argument("--partition", default=None, help="partition.txt: <inst> <die(0/1)> (die can be last token)")
    ap.add_argument("--cell-map", default=None, help="optional map.json with base/bottom/upper macro and tier pin_map")
    args = ap.parse_args()

    # Partition map (must exist if you want deterministic conversion)
    part = parse_partition_file(args.partition)
    (
        base_to_bottom,
        base_to_upper,
        base_to_bottom_pin_map,
        base_to_upper_pin_map,
        base_to_bottom_const_pins,
        base_to_upper_const_pins,
        base_to_tier_areas,
        has_heterogeneous_area_map,
        has_cell_map,
    ) = parse_cell_map_json(args.cell_map)

    part = choose_partition_orientation_by_area(
        part,
        args.def_in,
        base_to_tier_areas,
        has_heterogeneous_area_map,
    )
    if part and (not has_heterogeneous_area_map or not base_to_tier_areas):
        part = choose_partition_orientation_by_pins(part, args.def_in)

    if not part:
        print("[WARN] No partition map provided/parsed. Conversion will only apply JSON macro mapping where possible.")

    rewrite_def(
        args.def_in,
        args.def_out,
        part,
        base_to_bottom,
        base_to_upper,
        base_to_bottom_pin_map,
        base_to_upper_pin_map,
        has_cell_map,
    )
    rewrite_verilog(
        args.v_in,
        args.v_out,
        part,
        base_to_bottom,
        base_to_upper,
        base_to_bottom_pin_map,
        base_to_upper_pin_map,
        base_to_bottom_const_pins,
        base_to_upper_const_pins,
        has_cell_map,
    )

if __name__ == "__main__":
    main()
