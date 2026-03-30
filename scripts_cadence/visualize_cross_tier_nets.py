#!/usr/bin/env python3

import argparse
import html
import json
import re
import subprocess
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple


OUTPUT_PINS = {
    "Z",
    "ZN",
    "Q",
    "QN",
    "X",
    "Y",
    "S",
    "SO",
    "CO",
}

PORT_DECL_RE = re.compile(
    r"^\s*(input|output|inout)\s+(?:\[[^\]]+\]\s+)?([^;]+);",
    re.MULTILINE,
)
INST_RE = re.compile(
    r"^\s*(?!module\b|input\b|output\b|inout\b|wire\b|tri\b|assign\b|endmodule\b|supply0\b|supply1\b)"
    r"(\S+)\s+(\S+)\s*\((.*?)\);\s*$",
    re.MULTILINE | re.DOTALL,
)
PIN_RE = re.compile(r"\.([A-Za-z0-9_]+)\(([^()]+)\)")


@dataclass
class Connection:
    inst: str
    cell: str
    tier: str
    pin: str


@dataclass
class InstanceInfo:
    name: str
    cell: str
    tier: str
    pins: Dict[str, str] = field(default_factory=dict)


@dataclass
class NetInfo:
    name: str
    drivers: List[Connection] = field(default_factory=list)
    loads: List[Connection] = field(default_factory=list)
    terminals: List[str] = field(default_factory=list)


@dataclass
class NetlistData:
    path: Path
    instances: Dict[str, InstanceInfo] = field(default_factory=dict)
    nets: Dict[str, NetInfo] = field(default_factory=dict)
    ports: Set[str] = field(default_factory=set)


def normalize_name(token: str) -> str:
    text = token.strip()
    if text.startswith("\\"):
        text = text[1:]
    text = text.replace("\\[", "[").replace("\\]", "]")
    if text.startswith("{") and text.endswith("}") and text.count(" ") == 0:
        text = text[1:-1]
    return text


def tier_of_cell(cell: str) -> str:
    if cell.endswith("_upper"):
        return "upper"
    if cell.endswith("_bottom"):
        return "bottom"
    return "other"


def is_output_pin(pin: str) -> bool:
    return pin in OUTPUT_PINS


def is_synthetic_instance(inst_name: str) -> bool:
    return inst_name.startswith("FE_") or inst_name.startswith("fopt")


def sanitize_filename(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", name)


def quote_dot(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def get_or_create_net(data: NetlistData, net_name: str) -> NetInfo:
    if net_name not in data.nets:
        data.nets[net_name] = NetInfo(name=net_name)
    return data.nets[net_name]


def parse_ports(text: str) -> Set[str]:
    ports: Set[str] = set()
    for match in PORT_DECL_RE.finditer(text):
        for raw_name in match.group(2).split(","):
            name = normalize_name(raw_name)
            if name:
                ports.add(name)
    return ports


def parse_netlist(path: Path) -> NetlistData:
    text = path.read_text(encoding="utf-8", errors="ignore")
    data = NetlistData(path=path, ports=parse_ports(text))

    for match in INST_RE.finditer(text):
        cell = match.group(1)
        inst_name = normalize_name(match.group(2))
        body = match.group(3)
        tier = tier_of_cell(cell)
        inst_info = InstanceInfo(name=inst_name, cell=cell, tier=tier)

        for pin, raw_net in PIN_RE.findall(body):
            net_name = normalize_name(raw_net)
            if not net_name or net_name.startswith("1'b") or net_name.startswith("1'h"):
                continue
            inst_info.pins[pin] = net_name
            net_info = get_or_create_net(data, net_name)
            conn = Connection(inst=inst_name, cell=cell, tier=tier, pin=pin)
            if is_output_pin(pin):
                net_info.drivers.append(conn)
            else:
                net_info.loads.append(conn)

        data.instances[inst_name] = inst_info

    for port in data.ports:
        net_info = get_or_create_net(data, port)
        net_info.terminals.append(port)

    return data


def parse_cross_tier_report(path: Path) -> Dict[str, Dict[str, str]]:
    nets: Dict[str, Dict[str, str]] = {}
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "|" not in raw_line:
            continue
        line = raw_line.strip()
        if (
            not line
            or line.startswith("#")
            or line.startswith("Net Name")
            or line.startswith("-")
        ):
            continue
        net_raw, net_type = [part.strip() for part in raw_line.split("|", 1)]
        net_name = normalize_name(net_raw)
        nets[net_name] = {"display_name": net_raw.strip(), "type": net_type}
    return nets


def classify_net(net_name: str, data: NetlistData) -> str:
    net = data.nets.get(net_name)
    if not net:
        return "MISSING"

    has_upper = False
    has_bottom = False
    has_terminal = bool(net.terminals)

    for conn in net.drivers + net.loads:
        if conn.tier == "upper":
            has_upper = True
        elif conn.tier == "bottom":
            has_bottom = True

    if has_upper and has_bottom:
        return "Upper_Bottom"
    if has_upper and has_terminal:
        return "Upper_Terminal"
    if has_bottom and has_terminal:
        return "Bottom_Terminal"
    if has_upper:
        return "Upper_Only"
    if has_bottom:
        return "Bottom_Only"
    if has_terminal:
        return "Terminal_Only"
    return "Unknown"


def unique_preserve(values: Iterable[str]) -> List[str]:
    seen: Set[str] = set()
    out: List[str] = []
    for value in values:
        if value not in seen:
            out.append(value)
            seen.add(value)
    return out


def driver_input_nets(inst: InstanceInfo) -> List[str]:
    nets = [net for pin, net in inst.pins.items() if not is_output_pin(pin)]
    return unique_preserve(nets)


def driver_output_nets(inst: InstanceInfo) -> List[str]:
    nets = [net for pin, net in inst.pins.items() if is_output_pin(pin)]
    return unique_preserve(nets)


def trace_group_root(
    net_name: str,
    data: NetlistData,
    cross_union: Set[str],
) -> str:
    current = net_name
    visited: Set[str] = set()

    while current not in visited:
        visited.add(current)
        net = data.nets.get(current)
        if not net or len(net.drivers) != 1:
            return current

        driver = net.drivers[0]
        if not is_synthetic_instance(driver.inst):
            return current

        inst = data.instances.get(driver.inst)
        if not inst:
            return current

        parents = driver_input_nets(inst)
        if len(parents) != 1:
            return current

        parent = parents[0]
        if parent in cross_union and parent != net_name:
            return parent
        current = parent

    return current


def summarize_connection(conn: Connection) -> str:
    return f"{conn.inst}.{conn.pin} [{conn.cell}]"


def summarize_net_endpoints(net_name: str, data: NetlistData) -> Dict[str, List[str]]:
    net = data.nets.get(net_name)
    if not net:
        return {"drivers": [], "loads": [], "terminals": []}

    drivers = [summarize_connection(conn) for conn in net.drivers]
    loads = [summarize_connection(conn) for conn in net.loads]
    return {
        "drivers": drivers,
        "loads": loads,
        "terminals": list(net.terminals),
    }


def successor_nets_for_removed_net(
    net_name: str,
    before_data: NetlistData,
    after_data: NetlistData,
) -> List[Tuple[str, int]]:
    before_net = before_data.nets.get(net_name)
    if not before_net:
        return []

    counter: Counter[str] = Counter()
    for conn in before_net.loads:
        inst = after_data.instances.get(conn.inst)
        if not inst:
            continue
        new_net = inst.pins.get(conn.pin)
        if not new_net:
            continue
        counter[new_net] += 1
    return counter.most_common()


def introduced_by_for_added_net(net_name: str, after_data: NetlistData) -> Dict[str, List[str]]:
    net = after_data.nets.get(net_name)
    if not net:
        return {"drivers": [], "parent_nets": []}

    drivers = [summarize_connection(conn) for conn in net.drivers]
    parent_nets: List[str] = []
    for conn in net.drivers:
        inst = after_data.instances.get(conn.inst)
        if not inst:
            continue
        parent_nets.extend(driver_input_nets(inst))
    return {
        "drivers": drivers,
        "parent_nets": unique_preserve(parent_nets),
    }


class DotGraph:
    def __init__(self, title: str) -> None:
        self.title = title
        self.lines: List[str] = [
            "digraph G {",
            '  graph [rankdir=LR, labelloc=t, fontsize=18, fontname="Helvetica"];',
            '  node [fontname="Helvetica", fontsize=10, style=filled];',
            '  edge [fontname="Helvetica", fontsize=9];',
            f'  label="{quote_dot(title)}";',
        ]
        self.nodes: Set[str] = set()
        self.edges: Set[Tuple[str, str, str]] = set()

    def add_node(
        self,
        node_id: str,
        label: str,
        shape: str,
        fillcolor: str,
        color: str = "#334155",
        penwidth: int = 1,
    ) -> None:
        if node_id in self.nodes:
            return
        self.nodes.add(node_id)
        self.lines.append(
            f'  {node_id} [label="{quote_dot(label)}", shape={shape}, '
            f'fillcolor="{fillcolor}", color="{color}", penwidth={penwidth}];'
        )

    def add_edge(self, src: str, dst: str, label: str = "") -> None:
        key = (src, dst, label)
        if key in self.edges:
            return
        self.edges.add(key)
        extra = f' [label="{quote_dot(label)}"]' if label else ""
        self.lines.append(f"  {src} -> {dst}{extra};")

    def render(self) -> str:
        return "\n".join(self.lines + ["}"])


def net_node_style(
    net_name: str,
    data: NetlistData,
    root_net: str,
    added_nets: Set[str],
    removed_nets: Set[str],
) -> Tuple[str, str, str, int]:
    net_type = classify_net(net_name, data)
    label = f"net\\n{net_name}\\n{net_type}"
    if net_name == root_net:
        return label, "#fef3c7", "#b45309", 3
    if net_name in added_nets:
        return label + "\\nADDED", "#fee2e2", "#b91c1c", 3
    if net_name in removed_nets:
        return label + "\\nREMOVED", "#ede9fe", "#6d28d9", 3
    if net_type == "Upper_Bottom":
        return label, "#dbeafe", "#1d4ed8", 2
    if net_type == "Upper_Terminal":
        return label, "#dcfce7", "#15803d", 2
    return label, "#e5e7eb", "#475569", 1


def inst_node_style(inst: InstanceInfo) -> Tuple[str, str]:
    if inst.tier == "upper":
        return f"{inst.name}\\n{inst.cell}", "#dbeafe"
    if inst.tier == "bottom":
        return f"{inst.name}\\n{inst.cell}", "#ffedd5"
    return f"{inst.name}\\n{inst.cell}", "#e5e7eb"


def add_net_node(
    graph: DotGraph,
    net_name: str,
    data: NetlistData,
    root_net: str,
    added_nets: Set[str],
    removed_nets: Set[str],
) -> str:
    node_id = f'net_{sanitize_filename(net_name)}'
    label, fillcolor, color, penwidth = net_node_style(
        net_name,
        data,
        root_net,
        added_nets,
        removed_nets,
    )
    graph.add_node(
        node_id,
        label=label,
        shape="ellipse",
        fillcolor=fillcolor,
        color=color,
        penwidth=penwidth,
    )
    return node_id


def add_inst_node(graph: DotGraph, inst: InstanceInfo) -> str:
    node_id = f'inst_{sanitize_filename(inst.name)}'
    label, fillcolor = inst_node_style(inst)
    graph.add_node(
        node_id,
        label=label,
        shape="box",
        fillcolor=fillcolor,
        penwidth=2 if is_synthetic_instance(inst.name) else 1,
    )
    return node_id


def add_port_node(graph: DotGraph, port_name: str) -> str:
    node_id = f'port_{sanitize_filename(port_name)}'
    graph.add_node(
        node_id,
        label=f"port\\n{port_name}",
        shape="diamond",
        fillcolor="#f3f4f6",
    )
    return node_id


def add_driver_context(
    graph: DotGraph,
    net_name: str,
    data: NetlistData,
    root_net: str,
    added_nets: Set[str],
    removed_nets: Set[str],
) -> None:
    net = data.nets.get(net_name)
    if not net:
        return

    net_node = add_net_node(graph, net_name, data, root_net, added_nets, removed_nets)

    for driver in net.drivers:
        inst = data.instances.get(driver.inst)
        if not inst:
            continue
        inst_node = add_inst_node(graph, inst)
        graph.add_edge(inst_node, net_node, driver.pin)

        for parent_net in driver_input_nets(inst):
            parent_node = add_net_node(
                graph,
                parent_net,
                data,
                root_net,
                added_nets,
                removed_nets,
            )
            graph.add_edge(parent_node, inst_node, "")
            parent_info = data.nets.get(parent_net)
            if not parent_info:
                continue
            for upstream in parent_info.drivers:
                upstream_inst = data.instances.get(upstream.inst)
                if not upstream_inst:
                    continue
                upstream_node = add_inst_node(graph, upstream_inst)
                graph.add_edge(upstream_node, parent_node, upstream.pin)


def add_child_branch(
    graph: DotGraph,
    root_inst: InstanceInfo,
    data: NetlistData,
    root_net: str,
    added_nets: Set[str],
    removed_nets: Set[str],
) -> None:
    inst_node = add_inst_node(graph, root_inst)
    for child_net in driver_output_nets(root_inst):
        if child_net == root_net:
            continue
        child_info = data.nets.get(child_net)
        if not child_info:
            continue
        child_node = add_net_node(
            graph,
            child_net,
            data,
            root_net,
            added_nets,
            removed_nets,
        )
        driver_pin = ""
        for conn in child_info.drivers:
            if conn.inst == root_inst.name:
                driver_pin = conn.pin
                break
        graph.add_edge(inst_node, child_node, driver_pin)

        for port in child_info.terminals:
            port_node = add_port_node(graph, port)
            graph.add_edge(child_node, port_node, "")

        for load in child_info.loads:
            load_inst = data.instances.get(load.inst)
            if not load_inst:
                continue
            load_node = add_inst_node(graph, load_inst)
            graph.add_edge(child_node, load_node, load.pin)


def build_root_graph(
    root_net: str,
    data: NetlistData,
    title: str,
    added_nets: Set[str],
    removed_nets: Set[str],
) -> str:
    graph = DotGraph(title)
    root_info = data.nets.get(root_net)
    if not root_info:
        graph.add_node(
            "missing",
            label=f"missing\\n{root_net}",
            shape="ellipse",
            fillcolor="#fee2e2",
            color="#b91c1c",
            penwidth=3,
        )
        return graph.render()

    root_node = add_net_node(graph, root_net, data, root_net, added_nets, removed_nets)

    for port in root_info.terminals:
        port_node = add_port_node(graph, port)
        graph.add_edge(root_node, port_node, "")

    add_driver_context(graph, root_net, data, root_net, added_nets, removed_nets)

    for load in root_info.loads:
        inst = data.instances.get(load.inst)
        if not inst:
            continue
        inst_node = add_inst_node(graph, inst)
        graph.add_edge(root_node, inst_node, load.pin)
        if is_synthetic_instance(inst.name):
            add_child_branch(graph, inst, data, root_net, added_nets, removed_nets)

    return graph.render()


def write_graph(dot_text: str, dot_path: Path, svg_path: Path) -> None:
    dot_path.write_text(dot_text, encoding="utf-8")
    subprocess.run(
        ["dot", "-Tsvg", str(dot_path), "-o", str(svg_path)],
        check=True,
    )


def html_list(items: Iterable[str]) -> str:
    values = list(items)
    if not values:
        return "<span class='none'>None</span>"
    return "<ul>" + "".join(f"<li>{html.escape(item)}</li>" for item in values) + "</ul>"


def render_change_table(group: Dict[str, object]) -> str:
    rows: List[str] = []
    for item in group["changes"]:
        before_summary = item["before"]
        after_summary = item["after"]
        extra_lines = []
        if item["change"] == "added":
            extra_lines.append(
                "Introduced by: "
                + ", ".join(html.escape(x) for x in item["introduced_by"]["drivers"])
            )
            extra_lines.append(
                "Parent net(s): "
                + ", ".join(html.escape(x) for x in item["introduced_by"]["parent_nets"])
            )
        else:
            succ = item["successor_nets"]
            succ_text = ", ".join(f"{html.escape(net)} ({count})" for net, count in succ)
            extra_lines.append(
                "Loads moved to: " + (succ_text if succ_text else "None")
            )

        rows.append(
            "<tr>"
            f"<td>{html.escape(item['net'])}</td>"
            f"<td>{html.escape(item['change'])}</td>"
            f"<td>{html.escape(item['before_type'])}</td>"
            f"<td>{html.escape(item['after_type'])}</td>"
            f"<td>{html_list(before_summary['drivers'])}</td>"
            f"<td>{html_list(before_summary['loads'])}</td>"
            f"<td>{html_list(after_summary['drivers'])}</td>"
            f"<td>{html_list(after_summary['loads'])}</td>"
            f"<td>{'<br>'.join(html.escape(line) for line in extra_lines)}</td>"
            "</tr>"
        )
    return (
        "<table>"
        "<thead><tr>"
        "<th>Net</th><th>Change</th><th>Before Type</th><th>After Type</th>"
        "<th>Before Drivers</th><th>Before Loads</th>"
        "<th>After Drivers</th><th>After Loads</th>"
        "<th>Why Changed</th>"
        "</tr></thead>"
        "<tbody>"
        + "".join(rows)
        + "</tbody></table>"
    )


def build_summary(
    before_data: NetlistData,
    after_data: NetlistData,
    before_report: Dict[str, Dict[str, str]],
    after_report: Dict[str, Dict[str, str]],
) -> Dict[str, object]:
    before_nets = set(before_report)
    after_nets = set(after_report)
    cross_union = before_nets | after_nets

    added_nets = sorted(after_nets - before_nets)
    removed_nets = sorted(before_nets - after_nets)

    grouped: Dict[str, Dict[str, object]] = {}

    def ensure_group(root_net: str) -> Dict[str, object]:
        if root_net not in grouped:
            grouped[root_net] = {
                "root_net": root_net,
                "before_root_type": classify_net(root_net, before_data),
                "after_root_type": classify_net(root_net, after_data),
                "added_nets": [],
                "removed_nets": [],
                "changes": [],
            }
        return grouped[root_net]

    for net_name in added_nets:
        root_net = trace_group_root(net_name, after_data, cross_union)
        group = ensure_group(root_net)
        group["added_nets"].append(net_name)
        group["changes"].append(
            {
                "net": net_name,
                "change": "added",
                "before_type": classify_net(net_name, before_data),
                "after_type": classify_net(net_name, after_data),
                "before": summarize_net_endpoints(net_name, before_data),
                "after": summarize_net_endpoints(net_name, after_data),
                "introduced_by": introduced_by_for_added_net(net_name, after_data),
                "successor_nets": [],
            }
        )

    for net_name in removed_nets:
        root_net = trace_group_root(net_name, before_data, cross_union)
        group = ensure_group(root_net)
        group["removed_nets"].append(net_name)
        group["changes"].append(
            {
                "net": net_name,
                "change": "removed",
                "before_type": classify_net(net_name, before_data),
                "after_type": classify_net(net_name, after_data),
                "before": summarize_net_endpoints(net_name, before_data),
                "after": summarize_net_endpoints(net_name, after_data),
                "introduced_by": {"drivers": [], "parent_nets": []},
                "successor_nets": successor_nets_for_removed_net(
                    net_name,
                    before_data,
                    after_data,
                ),
            }
        )

    groups = []
    for root_net, group in sorted(grouped.items()):
        group["added_nets"].sort()
        group["removed_nets"].sort()
        group["changes"].sort(key=lambda item: (item["change"], item["net"]))
        groups.append(group)

    return {
        "before_count": len(before_nets),
        "after_count": len(after_nets),
        "added_nets": added_nets,
        "removed_nets": removed_nets,
        "groups": groups,
    }


def write_html(summary: Dict[str, object], out_dir: Path) -> None:
    sections: List[str] = []
    graphs_dir = out_dir / "graphs"

    for group in summary["groups"]:
        root_net = group["root_net"]
        base_name = sanitize_filename(root_net)
        before_svg = f"graphs/{base_name}.before.svg"
        after_svg = f"graphs/{base_name}.after.svg"
        sections.append(
            "<section>"
            f"<h2>{html.escape(root_net)}</h2>"
            "<div class='meta'>"
            f"<p><strong>Before Root Type:</strong> {html.escape(group['before_root_type'])}</p>"
            f"<p><strong>After Root Type:</strong> {html.escape(group['after_root_type'])}</p>"
            f"<p><strong>Added Cross-Tier Nets:</strong> {', '.join(html.escape(n) for n in group['added_nets']) or 'None'}</p>"
            f"<p><strong>Removed Cross-Tier Nets:</strong> {', '.join(html.escape(n) for n in group['removed_nets']) or 'None'}</p>"
            "</div>"
            "<div class='panels'>"
            "<div class='panel'>"
            "<h3>Before</h3>"
            f"<img src='{html.escape(before_svg)}' alt='before graph for {html.escape(root_net)}'>"
            "</div>"
            "<div class='panel'>"
            "<h3>After</h3>"
            f"<img src='{html.escape(after_svg)}' alt='after graph for {html.escape(root_net)}'>"
            "</div>"
            "</div>"
            "<h3>Changed Nets</h3>"
            f"{render_change_table(group)}"
            "</section>"
        )

    html_text = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Cross-Tier Net Visualization</title>
  <style>
    body {{
      font-family: Helvetica, Arial, sans-serif;
      margin: 24px;
      background: #f8fafc;
      color: #0f172a;
    }}
    h1, h2, h3 {{
      margin-bottom: 8px;
    }}
    .summary {{
      background: white;
      border: 1px solid #cbd5e1;
      border-radius: 12px;
      padding: 16px;
      margin-bottom: 20px;
    }}
    section {{
      background: white;
      border: 1px solid #cbd5e1;
      border-radius: 12px;
      padding: 16px;
      margin-bottom: 24px;
    }}
    .meta p {{
      margin: 4px 0;
    }}
    .panels {{
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 16px;
      margin: 16px 0;
    }}
    .panel {{
      border: 1px solid #e2e8f0;
      border-radius: 8px;
      padding: 12px;
      background: #fff;
    }}
    img {{
      width: 100%;
      height: auto;
      background: white;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }}
    th, td {{
      border: 1px solid #cbd5e1;
      padding: 8px;
      vertical-align: top;
      text-align: left;
    }}
    th {{
      background: #e2e8f0;
    }}
    ul {{
      margin: 0;
      padding-left: 18px;
    }}
    .none {{
      color: #64748b;
      font-style: italic;
    }}
  </style>
</head>
<body>
  <div class="summary">
    <h1>Cross-Tier Net Visualization</h1>
    <p><strong>Before Cross-Tier Nets:</strong> {summary['before_count']}</p>
    <p><strong>After Cross-Tier Nets:</strong> {summary['after_count']}</p>
    <p><strong>Added:</strong> {', '.join(html.escape(n) for n in summary['added_nets']) or 'None'}</p>
    <p><strong>Removed:</strong> {', '.join(html.escape(n) for n in summary['removed_nets']) or 'None'}</p>
    <p><strong>Output Directory:</strong> {html.escape(str(out_dir))}</p>
  </div>
  {''.join(sections)}
</body>
</html>
"""
    (out_dir / "index.html").write_text(html_text, encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Visualize before/after cross-tier net connectivity."
    )
    parser.add_argument("--before-netlist", required=True, type=Path)
    parser.add_argument("--after-netlist", required=True, type=Path)
    parser.add_argument("--before-report", required=True, type=Path)
    parser.add_argument("--after-report", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    graphs_dir = args.out_dir / "graphs"
    graphs_dir.mkdir(parents=True, exist_ok=True)

    before_data = parse_netlist(args.before_netlist)
    after_data = parse_netlist(args.after_netlist)
    before_report = parse_cross_tier_report(args.before_report)
    after_report = parse_cross_tier_report(args.after_report)
    summary = build_summary(before_data, after_data, before_report, after_report)

    for group in summary["groups"]:
        root_net = group["root_net"]
        base_name = sanitize_filename(root_net)
        added_nets = set(group["added_nets"])
        removed_nets = set(group["removed_nets"])

        before_dot = build_root_graph(
            root_net=root_net,
            data=before_data,
            title=f"{root_net} before",
            added_nets=added_nets,
            removed_nets=removed_nets,
        )
        after_dot = build_root_graph(
            root_net=root_net,
            data=after_data,
            title=f"{root_net} after",
            added_nets=added_nets,
            removed_nets=removed_nets,
        )

        write_graph(
            before_dot,
            graphs_dir / f"{base_name}.before.dot",
            graphs_dir / f"{base_name}.before.svg",
        )
        write_graph(
            after_dot,
            graphs_dir / f"{base_name}.after.dot",
            graphs_dir / f"{base_name}.after.svg",
        )

    (args.out_dir / "summary.json").write_text(
        json.dumps(summary, indent=2),
        encoding="utf-8",
    )
    write_html(summary, args.out_dir)

    print(f"Wrote report to {args.out_dir / 'index.html'}")


if __name__ == "__main__":
    main()
