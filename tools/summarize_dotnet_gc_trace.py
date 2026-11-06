#!/usr/bin/env python3
import argparse
import csv
import json
import statistics
from pathlib import Path


def percentile(values, p):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * p
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def read_events(path):
    records = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {error}") from error
    return records


def write_csv(path, rows, fieldnames=None):
    if not rows and fieldnames is None:
        raise ValueError(f"No data to write: {path}")
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames or list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description="Summarize separate .NET EventPipe GC traces.")
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    files = sorted(args.directory.glob("*.events.jsonl"))
    if not files:
        raise SystemExit(f"No EventPipe event files found in {args.directory}")

    pause_rows = []
    gc_rows = []
    summaries = []
    for event_file in files:
        status_file = event_file.with_suffix(".status.json")
        if not status_file.is_file():
            raise SystemExit(f"Trace status is missing: {status_file}")
        status = json.loads(status_file.read_text(encoding="utf-8-sig"))
        for field in (
            "lostEvents", "incompleteIntervals", "unmatchedResumeCount",
            "gcEventAssociationFailures", "conflictingGcStartEvents",
        ):
            if status.get(field, 0) != 0:
                raise SystemExit(f"{event_file.name}: {field}={status.get(field)}; diagnostic trace is incomplete")
        if status.get("measurementStartEvents") != 1 or status.get("measurementEndEvents") != 1:
            raise SystemExit(f"{event_file.name}: measurement interval markers are missing or duplicated")

        events = read_events(event_file)
        pauses = [event for event in events if event.get("event_name") == "GCPause"]
        collections = [event for event in events if event.get("event_name") == "GCStart"]
        if len(pauses) != status.get("pauseEvents"):
            raise SystemExit(
                f"{event_file.name}: parsed {len(pauses)} pauses, "
                f"trace parser reported {status.get('pauseEvents')}"
            )
        durations = [float(event["duration_ms"]) for event in pauses]
        for event in pauses:
            pause_rows.append({"run": event_file.name, **event})
        for event in collections:
            gc_rows.append({"run": event_file.name, **event})

        generations = {}
        gc_types = {}
        gc_reasons = {}
        for event in collections:
            generation = str(event.get("generation", "unknown"))
            gc_type = str(event.get("type", "unknown"))
            gc_reason = str(event.get("reason", "unknown"))
            generations[generation] = generations.get(generation, 0) + 1
            gc_types[gc_type] = gc_types.get(gc_type, 0) + 1
            gc_reasons[gc_reason] = gc_reasons.get(gc_reason, 0) + 1

        summaries.append({
            "run": event_file.name,
            "gc_start_events": len(collections),
            "pause_events": len(pauses),
            "pause_median_ms": statistics.median(durations) if durations else None,
            "pause_mean_ms": statistics.fmean(durations) if durations else None,
            "pause_stddev_ms": statistics.stdev(durations) if len(durations) > 1 else (0 if durations else None),
            "pause_q1_ms": percentile(durations, .25),
            "pause_q3_ms": percentile(durations, .75),
            "pause_p50_ms": percentile(durations, .50),
            "pause_p95_ms": percentile(durations, .95),
            "pause_p99_ms": percentile(durations, .99),
            "pause_min_ms": min(durations) if durations else None,
            "pause_max_ms": max(durations) if durations else None,
            "collections_by_generation": json.dumps(generations, sort_keys=True),
            "collections_by_type": json.dumps(gc_types, sort_keys=True),
            "collections_by_reason": json.dumps(gc_reasons, sort_keys=True),
            "eventpipe_lost_events": status["lostEvents"],
            "unmatched_pause_intervals": status["incompleteIntervals"] + status["unmatchedResumeCount"],
            "duplicate_gc_start_events": status.get("duplicateGcStartEvents", 0),
            "conflicting_gc_start_events": status.get("conflictingGcStartEvents", 0),
        })

    write_csv(
        args.directory / "pause-events.csv",
        pause_rows,
        ["run", "event_name", "start_timestamp_ms", "end_timestamp_ms", "duration_ms",
         "suspension_request_ms", "fully_suspended_ms", "resume_ms", "process_id",
         "suspend_reason", "suspend_gc_count", "generation", "gc_reason", "gc_type",
         "gc_count", "gc_start_timestamp_ms"],
    )
    write_csv(
        args.directory / "gc-start-events.csv",
        gc_rows,
        ["run", "event_name", "timestamp_ms", "process_id", "generation", "reason", "type", "count"],
    )
    write_csv(args.directory / "run-summary.csv", summaries)
    print(f"Summarized {len(summaries)} separate .NET EventPipe traces in {args.directory}")


if __name__ == "__main__":
    main()
