#!/usr/bin/env python3
"""Flatten one or more JSONL benchmark outputs into a CSV suitable for Excel."""
import argparse
import csv
import json
from pathlib import Path


def flatten(record):
    row = {k: v for k, v in record.items() if k not in {"metrics", "batch_latency_ms", "gc_collectors_delta"}}
    def add_nested(prefix, value):
        if isinstance(value, dict):
            for key, nested in value.items():
                add_nested(f"{prefix}.{key}", nested)
        else:
            row[prefix] = value

    for group in ("metrics", "batch_latency_ms"):
        for key, value in record.get(group, {}).items():
            add_nested(f"{group}.{key}", value)
    for collector, values in record.get("gc_collectors_delta", {}).items():
        for key, value in values.items():
            row[f"gc_collectors_delta.{collector}.{key}"] = value
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+", help="JSONL files produced by benchmark programs")
    ap.add_argument("-o", "--output", default="gc-results.csv")
    args = ap.parse_args()

    rows = []
    for name in args.files:
        path = Path(name)
        with path.open(encoding="utf-8") as f:
            for line_no, line in enumerate(f, 1):
                if not line.strip():
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise SystemExit(f"{path}:{line_no}: invalid JSON: {exc}")
                row = flatten(rec)
                row["source_file"] = str(path)
                rows.append(row)
    if not rows:
        raise SystemExit("No JSON records found")

    columns = []
    for row in rows:
        for key in row:
            if key not in columns:
                columns.append(key)
    with Path(args.output).open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {len(rows)} runs to {args.output}")


if __name__ == "__main__":
    main()
