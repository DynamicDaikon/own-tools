#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def escape_label(value):
    if value is None:
        return ""

    return (
        str(value)
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", " ")
        .replace("\r", " ")
        .replace("[", "&#91;")
        .replace("]", "&#93;")
    )


def to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def cost_level(cost, thresholds):
    if cost is None:
        return None

    small, medium, large = thresholds

    if cost >= large:
        return "costHigh"
    if cost >= medium:
        return "costMid"
    if cost >= small:
        return "costLow"

    return None


class MermaidBuilder:
    def __init__(self, thresholds):
        self.lines = []
        self.counter = 0
        self.thresholds = thresholds

    def new_id(self, prefix="N"):
        self.counter += 1
        return f"{prefix}{self.counter}"

    def add_node(self, label, shape="rect", cost=None):
        node_id = self.new_id()
        label = escape_label(label)

        level = cost_level(cost, self.thresholds)

        if level == "costHigh":
            shape = "diamond"

        if shape == "round":
            self.lines.append(f'    {node_id}("{label}")')
        elif shape == "subroutine":
            self.lines.append(f'    {node_id}[["{label}"]]')
        elif shape == "diamond":
            self.lines.append(f'    {node_id}{{"{label}"}}')
        else:
            self.lines.append(f'    {node_id}["{label}"]')

        if level:
            self.lines.append(f"    class {node_id} {level}")

        return node_id

    def add_edge(self, src, dst, label=None):
        if not src or not dst:
            return

        if label:
            self.lines.append(f'    {src} -->|{escape_label(label)}| {dst}')
        else:
            self.lines.append(f"    {src} --> {dst}")


def table_label(table):
    name = table.get("table_name", "unknown_table")
    access = table.get("access_type", "")
    key = table.get("key", "")
    rows = table.get("rows_examined_per_scan", "")
    filtered = table.get("filtered", "")

    cost = table.get("cost_info", {})
    prefix_cost = cost.get("prefix_cost", "")

    return (
        f"{name}<br/>"
        f"access: {access}<br/>"
        f"key: {key}<br/>"
        f"rows: {rows}<br/>"
        f"filtered: {filtered}<br/>"
        f"cost: {prefix_cost}"
    )


def parse_query_block(block, builder, parent=None, edge_label=None):
    select_id = block.get("select_id", "?")
    query_cost = to_float(block.get("cost_info", {}).get("query_cost"))

    qb = builder.add_node(
        f"query_block<br/>select_id: {select_id}<br/>"
        f"cost: {query_cost if query_cost is not None else ''}",
        shape="round",
        cost=query_cost,
    )

    if parent:
        builder.add_edge(parent, qb, edge_label)

    if "nested_loop" in block:
        parse_nested_loop(block["nested_loop"], builder, qb)

    if "table" in block:
        parse_table(block["table"], builder, qb)

    if "grouping_operation" in block:
        parse_operation("grouping_operation", block["grouping_operation"], builder, qb)

    if "windowing" in block:
        parse_windowing(block["windowing"], builder, qb)

    if "union_result" in block:
        parse_union(block["union_result"], builder, qb)

    return qb


def parse_nested_loop(nested_loop, builder, parent):
    loop_node = builder.add_node("nested_loop<br/>JOIN order", shape="subroutine")
    builder.add_edge(parent, loop_node)

    prev = None

    for i, item in enumerate(nested_loop, start=1):
        step_node = builder.add_node(f"JOIN step {i}", shape="round")
        builder.add_edge(loop_node if prev is None else prev, step_node)

        if "table" in item:
            table_node = parse_table(item["table"], builder, step_node)
            prev = table_node
        else:
            parse_any(item, builder, step_node)
            prev = step_node


def parse_table(table, builder, parent):
    cost = to_float(table.get("cost_info", {}).get("prefix_cost"))

    node = builder.add_node(table_label(table), shape="rect", cost=cost)
    builder.add_edge(parent, node)

    if "materialized_from_subquery" in table:
        sub = table["materialized_from_subquery"]

        mat_label = (
            "materialized_from_subquery<br/>"
            f"temporary: {sub.get('using_temporary_table', '')}<br/>"
            f"dependent: {sub.get('dependent', '')}<br/>"
            f"cacheable: {sub.get('cacheable', '')}"
        )

        mat_node = builder.add_node(mat_label, shape="subroutine")
        builder.add_edge(node, mat_node)

        if "query_block" in sub:
            parse_query_block(sub["query_block"], builder, mat_node)

    return node


def parse_operation(name, operation, builder, parent):
    label = (
        f"{name}<br/>"
        f"temporary: {operation.get('using_temporary_table', '')}<br/>"
        f"filesort: {operation.get('using_filesort', '')}"
    )

    op_node = builder.add_node(label, shape="subroutine")
    builder.add_edge(parent, op_node)

    parse_any(operation, builder, op_node)

    return op_node


def parse_windowing(windowing, builder, parent):
    sort_cost = to_float(windowing.get("cost_info", {}).get("sort_cost"))

    win_node = builder.add_node(
        f"windowing<br/>sort_cost: {sort_cost if sort_cost is not None else ''}",
        shape="subroutine",
        cost=sort_cost,
    )
    builder.add_edge(parent, win_node)

    for i, window in enumerate(windowing.get("windows", []), start=1):
        funcs = ", ".join(window.get("functions", []))
        filesort = window.get("using_filesort", "")
        keys = "<br/>".join(window.get("filesort_key", []))

        w_node = builder.add_node(
            f"window {i}<br/>"
            f"functions: {funcs}<br/>"
            f"filesort: {filesort}<br/>"
            f"{keys}",
            shape="round",
        )
        builder.add_edge(win_node, w_node)

    if "table" in windowing:
        parse_table(windowing["table"], builder, win_node)

    return win_node


def parse_union(union_result, builder, parent):
    union_node = builder.add_node(
        f"union_result<br/>temporary: {union_result.get('using_temporary_table', '')}",
        shape="subroutine",
    )
    builder.add_edge(parent, union_node)

    for i, spec in enumerate(union_result.get("query_specifications", []), start=1):
        spec_node = builder.add_node(f"UNION branch {i}", shape="round")
        builder.add_edge(union_node, spec_node)

        if "query_block" in spec:
            parse_query_block(spec["query_block"], builder, spec_node)

    return union_node


def parse_any(obj, builder, parent):
    if not isinstance(obj, dict):
        return

    if "nested_loop" in obj:
        parse_nested_loop(obj["nested_loop"], builder, parent)

    if "table" in obj:
        parse_table(obj["table"], builder, parent)

    if "grouping_operation" in obj:
        parse_operation("grouping_operation", obj["grouping_operation"], builder, parent)

    if "windowing" in obj:
        parse_windowing(obj["windowing"], builder, parent)

    if "union_result" in obj:
        parse_union(obj["union_result"], builder, parent)


def build_markdown(data, thresholds):
    builder = MermaidBuilder(thresholds)

    builder.lines.append("# MySQL EXPLAIN Visualized")
    builder.lines.append("")
    builder.lines.append("```mermaid")
    builder.lines.append("flowchart TD")

    if "query_block" in data:
        parse_query_block(data["query_block"], builder)
    else:
        parse_any(data, builder, None)

    builder.lines.append("")
    builder.lines.append(
        "    classDef costLow "
        "fill:#fff7cc,stroke:#d6a700,stroke-width:2px,color:#000;"
    )
    builder.lines.append(
        "    classDef costMid "
        "fill:#ffe0b2,stroke:#ef6c00,stroke-width:3px,color:#000;"
    )
    builder.lines.append(
        "    classDef costHigh "
        "fill:#ffcdd2,stroke:#c62828,stroke-width:4px,color:#000,font-weight:bold;"
    )

    builder.lines.append("```")
    builder.lines.append("")

    return "\n".join(builder.lines)


def main():
    parser = argparse.ArgumentParser(
        description="Convert MySQL EXPLAIN FORMAT=JSON to nested Mermaid markdown."
    )

    parser.add_argument("input_json", help="Path to EXPLAIN FORMAT=JSON file")
    parser.add_argument("output_md", help="Path to output markdown file")

    parser.add_argument(
        "--cost-small",
        type=float,
        default=1000,
        help="Cost threshold for low warning. Default: 1000",
    )
    parser.add_argument(
        "--cost-medium",
        type=float,
        default=10000,
        help="Cost threshold for medium warning. Default: 10000",
    )
    parser.add_argument(
        "--cost-large",
        type=float,
        default=100000,
        help="Cost threshold for high warning. Default: 100000",
    )

    args = parser.parse_args()

    input_path = Path(args.input_json)
    output_path = Path(args.output_md)

    if not input_path.exists():
        raise FileNotFoundError(f"Input JSON file not found: {input_path}")

    with input_path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    thresholds = (args.cost_small, args.cost_medium, args.cost_large)
    markdown = build_markdown(data, thresholds)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(markdown, encoding="utf-8")

    print(f"Generated: {output_path}")


if __name__ == "__main__":
    main()
