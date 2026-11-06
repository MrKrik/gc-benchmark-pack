#!/usr/bin/env python3
"""Batch analysis of top-level JFR jdk.GCPhasePause events.

Outputs:
  pause_events.csv       one row per top-level STW pause event
  per_run_summary.csv    one row per JFR recording / process run
  scenario_summary.csv  medians and IQRs across independent process runs

Only jdk.GCPhasePause is counted. Nested GCPhasePauseLevel* events are
intentionally excluded to prevent double-counting.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import shutil
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

DURATION_RE = re.compile(
    r"^PT(?:(?P<h>\d+(?:\.\d+)?)H)?(?:(?P<m>\d+(?:\.\d+)?)M)?(?:(?P<s>\d+(?:\.\d+)?)S)?$"
)
RUN_RE = re.compile(r"^(?:java-)?(?P<scenario>.+?)-run-(?P<run>\d+)$", re.IGNORECASE)


def duration_seconds(value: str) -> float:
    match = DURATION_RE.fullmatch(value)
    if not match:
        raise ValueError(f"Unsupported JFR ISO-8601 duration: {value!r}")
    return (
        float(match.group("h") or 0) * 3600
        + float(match.group("m") or 0) * 60
        + float(match.group("s") or 0)
    )


def percentile_inc(values: list[float], p: float) -> float | None:
    """Linear-interpolated percentile equivalent to PERCENTILE.INC."""
    if not values:
        return None
    xs = sorted(values)
    if len(xs) == 1:
        return xs[0]
    position = (len(xs) - 1) * p
    lo = math.floor(position)
    hi = math.ceil(position)
    if lo == hi:
        return xs[lo]
    fraction = position - lo
    return xs[lo] + (xs[hi] - xs[lo]) * fraction


def fmt(value: float | None) -> str:
    return "" if value is None else f"{value:.6f}"


def find_jfr(command: str | None) -> str:
    if command:
        return command
    found = shutil.which("jfr") or shutil.which("jfr.exe")
    if found:
        return found
    raise FileNotFoundError(
        "Команда jfr не найдена в PATH. Добавьте папку JDK\\bin в PATH "
        "или передайте --jfr-command с полным путём к jfr.exe."
    )


def read_events(jfr: str, recording: Path) -> list[dict]:
    completed = subprocess.run(
        [jfr, "print", "--json", "--events", "jdk.GCPhasePause", str(recording)],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    doc = json.loads(completed.stdout)
    result = []
    for event in doc.get("recording", {}).get("events", []):
        values = event.get("values", {})
        duration = values.get("duration")
        if not duration:
            continue
        result.append({
            "start_time_utc": values.get("startTime", ""),
            "gc_id": values.get("gcId", ""),
            "event_name": values.get("name", ""),
            "duration_ms": duration_seconds(duration) * 1000.0,
        })
    return result


def identify(path: Path) -> tuple[str, str]:
    match = RUN_RE.match(path.stem)
    if match:
        return match.group("scenario"), match.group("run")
    return "unknown", path.stem


def write_csv(path: Path, columns: list[str], rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="Directory with *.jfr files or one .jfr file")
    parser.add_argument("--out", default="results/jfr-analysis", help="Output directory")
    parser.add_argument("--scenario", help="Only process a scenario, e.g. transient")
    parser.add_argument("--jfr-command", help="Path to jfr.exe / jfr executable")
    args = parser.parse_args()

    source = Path(args.source)
    if source.is_file():
        files = [source] if source.suffix.lower() == ".jfr" else []
    elif source.is_dir():
        files = sorted(source.glob("*.jfr"))
    else:
        files = []
    if args.scenario:
        files = [p for p in files if identify(p)[0].lower() == args.scenario.lower()]
    if not files:
        print("Не найдено JFR-файлов для обработки.", file=sys.stderr)
        return 2

    jfr = find_jfr(args.jfr_command)
    out_dir = Path(args.out)
    all_events: list[dict] = []
    per_run: list[dict] = []
    failures = []

    for recording in files:
        scenario, run_id = identify(recording)
        try:
            events = read_events(jfr, recording)
        except Exception as exc:  # preserve other recordings if one file is bad
            failures.append((recording.name, str(exc)))
            continue

        durations = [e["duration_ms"] for e in events]
        for event in events:
            all_events.append({
                "scenario": scenario,
                "run": run_id,
                "recording": recording.name,
                **event,
            })
        per_run.append({
            "scenario": scenario,
            "run": run_id,
            "recording": recording.name,
            "pause_count": len(durations),
            "total_pause_ms": fmt(sum(durations)),
            "mean_pause_ms": fmt(statistics.mean(durations) if durations else None),
            "p50_pause_ms": fmt(percentile_inc(durations, 0.50)),
            "p95_pause_ms": fmt(percentile_inc(durations, 0.95)),
            "p99_pause_ms": fmt(percentile_inc(durations, 0.99)),
            "max_pause_ms": fmt(max(durations) if durations else None),
        })

    write_csv(
        out_dir / "pause_events.csv",
        ["scenario", "run", "recording", "start_time_utc", "gc_id", "event_name", "duration_ms"],
        all_events,
    )
    write_csv(
        out_dir / "per_run_summary.csv",
        ["scenario", "run", "recording", "pause_count", "total_pause_ms", "mean_pause_ms", "p50_pause_ms", "p95_pause_ms", "p99_pause_ms", "max_pause_ms"],
        per_run,
    )

    grouped: dict[str, list[dict]] = defaultdict(list)
    for row in per_run:
        grouped[row["scenario"]].append(row)
    summary_rows = []
    metric_names = ["pause_count", "total_pause_ms", "mean_pause_ms", "p50_pause_ms", "p95_pause_ms", "p99_pause_ms", "max_pause_ms"]
    for scenario, rows in sorted(grouped.items()):
        out = {"scenario": scenario, "runs": len(rows)}
        for metric in metric_names:
            vals = [float(r[metric]) for r in rows if r[metric] != ""]
            out[f"median_{metric}"] = fmt(statistics.median(vals) if vals else None)
            out[f"q1_{metric}"] = fmt(percentile_inc(vals, 0.25))
            out[f"q3_{metric}"] = fmt(percentile_inc(vals, 0.75))
        summary_rows.append(out)
    summary_columns = ["scenario", "runs"] + [
        col for m in metric_names for col in (f"median_{m}", f"q1_{m}", f"q3_{m}")
    ]
    write_csv(out_dir / "scenario_summary.csv", summary_columns, summary_rows)

    print(f"Обработано записей JFR: {len(per_run)} из {len(files)}")
    print(f"STW-событий jdk.GCPhasePause: {len(all_events)}")
    print(f"Результаты: {out_dir.resolve()}")
    print("Созданы: pause_events.csv, per_run_summary.csv, scenario_summary.csv")
    if failures:
        print("Ошибки:", file=sys.stderr)
        for name, error in failures:
            print(f"  {name}: {error}", file=sys.stderr)
        return 1
    print("Учтены только верхнеуровневые jdk.GCPhasePause; вложенные Level1/2/3 исключены.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
