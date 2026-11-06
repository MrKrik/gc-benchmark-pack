#!/usr/bin/env python3
"""Extract jdk.GCPhasePause event durations from a JFR recording."""
import argparse
import csv
import json
import re
import subprocess
from pathlib import Path


def iso_duration_seconds(value: str) -> float:
    # JFR emits ISO-8601 durations such as PT0.003873761S or PT1.25S.
    match = re.fullmatch(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?", value)
    if not match:
        raise ValueError(f"Unsupported JFR duration: {value}")
    hours = float(match.group(1) or 0)
    minutes = float(match.group(2) or 0)
    seconds = float(match.group(3) or 0)
    return hours * 3600 + minutes * 60 + seconds


def percentile(sorted_values, p):
    """Linear-interpolated percentile (same definition as PERCENTILE.INC)."""
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = (len(sorted_values) - 1) * p
    lo = int(position)
    hi = min(lo + 1, len(sorted_values) - 1)
    fraction = position - lo
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * fraction


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recording", help="JFR file recorded by GcBench --jfr-file")
    ap.add_argument("-o", "--output", default="jfr-gc-pauses.csv", help="CSV with individual GC pause events")
    args = ap.parse_args()

    result = subprocess.run(
        ["jfr", "print", "--json", "--events", "jdk.GCPhasePause", args.recording],
        check=True, capture_output=True, text=True,
    )
    document = json.loads(result.stdout)
    events = []
    for event in document.get("recording", {}).get("events", []):
        values = event.get("values", {})
        duration_ms = iso_duration_seconds(values["duration"]) * 1000.0
        events.append({
            "start_time_utc": values.get("startTime", ""),
            "gc_id": values.get("gcId", ""),
            "phase_name": values.get("name", ""),
            "duration_ms": duration_ms,
        })

    with Path(args.output).open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=["start_time_utc", "gc_id", "phase_name", "duration_ms"])
        writer.writeheader()
        writer.writerows(events)

    values = sorted(e["duration_ms"] for e in events)
    summary = {
        "recording": str(args.recording),
        "events": len(values),
        "total_pause_ms": sum(values),
        "p50_ms": percentile(values, 0.50),
        "p95_ms": percentile(values, 0.95),
        "p99_ms": percentile(values, 0.99),
        "max_ms": max(values) if values else None,
        "events_csv": args.output,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
