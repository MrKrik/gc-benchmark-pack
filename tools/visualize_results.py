#!/usr/bin/env python3
import argparse
import csv
import html
import statistics
import subprocess
import sys
from pathlib import Path


PLATFORM_ORDER = ["go", "dotnet", "java"]
METRICS = [
    ("logical_nodes_per_second", "Узлов в секунду", "nodes/s"),
    ("elapsed_ms", "Время выполнения", "ms"),
    ("batch_latency_ms.p50", "p50 задержки партии", "ms"),
    ("batch_latency_ms.p95", "p95 задержки партии", "ms"),
    ("batch_latency_ms.p99", "p99 задержки партии", "ms"),
]
DIAGNOSTIC_METRICS = [
    ("go_gc_cycles", "Go: полные циклы GC (NumGC)", "cycles", {
        "go": "metrics.gc_cycles_delta",
    }, "Счётчик Go NumGC; не сравнивать с поколенческими .NET и MXBean-счётчиками Java."),
    ("dotnet_gen0", ".NET: сборки Gen 0", "collections", {
        "dotnet": "metrics.gen0_collections_delta",
    }, "Счётчик .NET для поколения 0."),
    ("dotnet_gen1", ".NET: сборки Gen 1", "collections", {
        "dotnet": "metrics.gen1_collections_delta",
    }, "Счётчик .NET для поколения 1."),
    ("dotnet_gen2", ".NET: сборки Gen 2", "collections", {
        "dotnet": "metrics.gen2_collections_delta",
    }, "Счётчик .NET для поколения 2."),
    ("go_stw_pause_ms", "Go: сумма STW-пауз", "ms", {
        "go": "metrics.gc_stw_pause_total_ms_delta",
    }, "Go runtime-счётчик; семантически не объединять с .NET или Java."),
    ("dotnet_stw_pause_ms", ".NET: сумма GC-пауз", "ms", {
        "dotnet": "metrics.gc_stw_pause_total_ms_delta",
    }, "GC.GetTotalPauseDuration; семантически не объединять с Go или Java."),
    ("go_pause_p50", "Go: p50 паузы GC (оценка гистограммы)", "ms", {
        "go": "metrics.gc_pause_duration_histogram_ms.p50_approx",
    }, "Оценка по серединам runtime histogram buckets; дельта охватывает весь интервал, а не только последние 256 циклов."),
    ("go_pause_p95", "Go: p95 паузы GC (оценка гистограммы)", "ms", {
        "go": "metrics.gc_pause_duration_histogram_ms.p95_approx",
    }, "Оценка по серединам runtime histogram buckets; это не точные сырые длительности."),
    ("dotnet_pause_p50", ".NET: p50 наблюдённых пауз", "ms", {
        "dotnet": "metrics.gc_pause_durations_ms.p50",
    }, "PauseDurations считываются после батчей; несколько сборок внутри одного батча могут быть пропущены."),
    ("dotnet_pause_p95", ".NET: p95 наблюдённых пауз", "ms", {
        "dotnet": "metrics.gc_pause_durations_ms.p95",
    }, "PauseDurations считываются после батчей; несколько сборок внутри одного батча могут быть пропущены."),
    ("go_gc_cpu_seconds", "Go: оценка CPU-времени GC", "s", {
        "go": "metrics.gc_cpu_seconds_estimated_delta",
    }, "Оценка runtime, не эквивалент CPU-счётчика других платформ."),
    ("heap_after_full_gc", "Heap после полной GC", "bytes", {
        "go": "metrics.heap_live_bytes_after_full_gc",
        "dotnet": "metrics.heap_used_bytes_after_full_gc",
        "java": "metrics.heap_used_bytes_after_full_gc",
    }, "Снимок после явного запроса полной GC; не RSS, физическая память или строго эквивалентное представление heap."),
    ("allocated_bytes_per_second", "Скорость аллокации (runtime-specific)", "bytes/s", {
        "go": "allocated_bytes_per_second",
        "dotnet": "allocated_bytes_per_second",
        "java": "allocated_bytes_per_second",
    }, "Охват: Go/.NET — процесс; Java — только поток теста, без JVM-служебных потоков. Метрика runtime-specific; не сравнивать напрямую."),
]
DIAGNOSTIC_VALUE_PATHS = {
    name: paths for name, _, _, paths, _ in DIAGNOSTIC_METRICS
}
COLORS = {"go": "#4c78a8", "dotnet": "#f58518", "java": "#54a24b"}


def load_rows(path):
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def compact(value):
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.2f}B"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f}M"
    if value >= 1_000:
        return f"{value / 1_000:.2f}K"
    return f"{value:.2f}"


def metric_value(row, column):
    if column in DIAGNOSTIC_VALUE_PATHS:
        path = DIAGNOSTIC_VALUE_PATHS[column].get(row.get("platform"))
        return number(row.get(path)) if path else None
    if column == "large_buffers_per_second":
        buffers = number(row.get("large_buffers_created"))
        elapsed_ms = number(row.get("elapsed_ms"))
        if buffers is None or elapsed_ms is None or elapsed_ms <= 0:
            return None
        return buffers * 1000 / elapsed_ms
    return number(row.get(column))


def quantile_inc(values, p):
    ordered = sorted(values)
    position = (len(ordered) - 1) * p
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def median_ci95(values):
    ordered = sorted(values)
    count = len(ordered)
    if count < 6:
        return None

    rank = None
    denominator = 1 << count
    tail_count = 0
    combination = 1
    for candidate in range(1, count // 2 + 1):
        tail_count += combination
        if 40 * tail_count > denominator:
            break
        rank = candidate
        combination = combination * (count - candidate + 1) // candidate
    if rank is None:
        return None
    return ordered[rank - 1], ordered[count - rank]


def summarize(rows, column):
    grouped = {}
    for row in rows:
        value = metric_value(row, column)
        if value is not None and row["platform"]:
            grouped.setdefault(row["platform"], []).append(value)

    result = {}
    for platform in PLATFORM_ORDER:
        values = grouped.get(platform, [])
        if values:
            interval = median_ci95(values)
            result[platform] = {
                "runs": len(values),
                "mean": statistics.fmean(values),
                "median": statistics.median(values),
                "q1": quantile_inc(values, 0.25),
                "q3": quantile_inc(values, 0.75),
                "median_ci95": interval,
                "std": statistics.stdev(values) if len(values) > 1 else 0,
                "min": min(values),
                "max": max(values),
                "values": sorted(values),
            }
    return result


def bar_chart(rows, column, title, unit, output):
    stats = summarize(rows, column)
    if not stats:
        output.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 760 390">'
            '<rect width="100%" height="100%" fill="white"/>'
            f'<text x="380" y="195" text-anchor="middle" font-family="Segoe UI" font-size="18">Нет данных для метрики {html.escape(title)}</text>'
            '</svg>',
            encoding="utf-8",
        )
        return
    width, height = 760, 390
    left, right, top, bottom = 100, 35, 55, 90
    plot_width = width - left - right
    plot_height = height - top - bottom
    maximum = max(item["q3"] for item in stats.values())
    if maximum == 0:
        output.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 760 390">'
            '<rect width="100%" height="100%" fill="white"/>'
            f'<text x="380" y="195" text-anchor="middle" font-family="Segoe UI" font-size="18">Метрика {html.escape(title)} равна нулю во всех запусках</text>'
            '</svg>',
            encoding="utf-8",
        )
        return
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width / 2}" y="27" text-anchor="middle" font-family="Segoe UI" font-size="18" font-weight="600">{html.escape(title)}</text>',
    ]
    for i in range(6):
        y = top + plot_height * i / 5
        value = maximum * (5 - i) / 5
        parts.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width - right}" y2="{y:.1f}" stroke="#d9e2ec"/>')
        parts.append(f'<text x="{left - 10}" y="{y + 4:.1f}" text-anchor="end" font-family="Segoe UI" font-size="12">{compact(value)}</text>')

    slot = plot_width / len(stats)
    for index, (platform, item) in enumerate(stats.items()):
        bar_width = min(100, slot * 0.55)
        bar_height = item["median"] / maximum * plot_height
        x = left + slot * index + (slot - bar_width) / 2
        y = top + plot_height - bar_height
        parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_width:.1f}" height="{bar_height:.1f}" rx="4" fill="{COLORS.get(platform, "#999")}"/>')
        q1_y = top + plot_height - item["q1"] / maximum * plot_height
        q3_y = top + plot_height - item["q3"] / maximum * plot_height
        center = x + bar_width / 2
        parts.append(f'<line x1="{center:.1f}" y1="{q3_y:.1f}" x2="{center:.1f}" y2="{q1_y:.1f}" stroke="#172b4d" stroke-width="2"/>')
        parts.append(f'<line x1="{center - 8:.1f}" y1="{q1_y:.1f}" x2="{center + 8:.1f}" y2="{q1_y:.1f}" stroke="#172b4d" stroke-width="2"/>')
        parts.append(f'<line x1="{center - 8:.1f}" y1="{q3_y:.1f}" x2="{center + 8:.1f}" y2="{q3_y:.1f}" stroke="#172b4d" stroke-width="2"/>')
        parts.append(f'<text x="{center:.1f}" y="{min(y - 8, top + plot_height - 8):.1f}" text-anchor="middle" font-family="Segoe UI" font-size="13" font-weight="600">{compact(item["median"])}</text>')
        parts.append(f'<text x="{x + bar_width / 2:.1f}" y="{top + plot_height + 25:.1f}" text-anchor="middle" font-family="Segoe UI" font-size="14">{html.escape(platform)}</text>')
        parts.append(f'<text x="{x + bar_width / 2:.1f}" y="{top + plot_height + 45:.1f}" text-anchor="middle" font-family="Segoe UI" font-size="11" fill="#667">{item["runs"]} runs</text>')
    parts.append(f'<text x="{width / 2}" y="{height - 12}" text-anchor="middle" font-family="Segoe UI" font-size="12" fill="#667">{html.escape(unit)}</text>')
    parts.append("</svg>")
    output.write_text("\n".join(parts), encoding="utf-8")


def run_strip(rows, column, title, output):
    stats = summarize(rows, column)
    if not stats:
        return
    width, height = 760, 390
    left, right, top, bottom = 100, 35, 55, 85
    values = [v for item in stats.values() for v in item["values"]]
    low, high = min(values), max(values)
    span = high - low or 1
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width / 2}" y="27" text-anchor="middle" font-family="Segoe UI" font-size="18" font-weight="600">{html.escape(title)}</text>',
    ]
    plot_width = width - left - right
    plot_height = height - top - bottom
    slot = plot_width / len(stats)
    for i in range(6):
        y = top + plot_height * i / 5
        value = high - span * i / 5
        parts.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width - right}" y2="{y:.1f}" stroke="#d9e2ec"/>')
        parts.append(f'<text x="{left - 10}" y="{y + 4:.1f}" text-anchor="end" font-family="Segoe UI" font-size="12">{compact(value)}</text>')
    for index, (platform, item) in enumerate(stats.items()):
        x = left + slot * index + slot / 2
        for run_index, value in enumerate(item["values"]):
            y = top + plot_height - (value - low) / span * plot_height
            jitter = ((run_index % 5) - 2) * 5
            parts.append(f'<circle cx="{x + jitter:.1f}" cy="{y:.1f}" r="5" fill="{COLORS.get(platform, "#999")}" opacity="0.75"/>')
        parts.append(f'<text x="{x:.1f}" y="{top + plot_height + 25:.1f}" text-anchor="middle" font-family="Segoe UI" font-size="14">{html.escape(platform)}</text>')
    parts.append("</svg>")
    output.write_text("\n".join(parts), encoding="utf-8")


def percent_change(primary, baseline):
    return (primary / baseline - 1) * 100 if baseline else 0


def jfr_report_section(scenario, analysis_dir):
    if analysis_dir is None:
        return ""

    summary_path = analysis_dir / "scenario_summary.csv"
    per_run_path = analysis_dir / "per_run_summary.csv"
    if not summary_path.is_file():
        raise FileNotFoundError(f"JFR scenario summary not found: {summary_path}")

    scenario_rows = [
        row for row in load_rows(summary_path)
        if row.get("scenario") == scenario
    ]
    if not scenario_rows:
        return (
            '<section><h2>Java JFR — паузы GC</h2>'
            f'<p>Для сценария {html.escape(scenario)} нет обработанных JFR-записей.</p></section>'
        )

    row = scenario_rows[0]
    metrics = [
        ("Число пауз", "pause_count", "событий"),
        ("Суммарные паузы", "total_pause_ms", "мс"),
        ("Средняя пауза", "mean_pause_ms", "мс"),
        ("p50 пауз", "p50_pause_ms", "мс"),
        ("p95 пауз", "p95_pause_ms", "мс"),
        ("p99 пауз", "p99_pause_ms", "мс"),
        ("Максимальная пауза", "max_pause_ms", "мс"),
    ]
    summary_table_rows = []
    for label, key, unit in metrics:
        median = row.get(f"median_{key}", "")
        q1 = row.get(f"q1_{key}", "")
        q3 = row.get(f"q3_{key}", "")
        summary_table_rows.append(
            "<tr>"
            f"<td>{html.escape(label)}</td>"
            f"<td>{html.escape(median)}</td>"
            f"<td>{html.escape(q1)}</td>"
            f"<td>{html.escape(q3)}</td>"
            f"<td>{html.escape(unit)}</td>"
            "</tr>"
        )

    run_table = ""
    if per_run_path.is_file():
        run_rows = [
            item for item in load_rows(per_run_path)
            if item.get("scenario") == scenario
        ]
        if run_rows:
            columns = [
                ("run", "Запуск"),
                ("recording", "JFR-файл"),
                ("pause_count", "Число пауз"),
                ("total_pause_ms", "Сумма, мс"),
                ("p50_pause_ms", "p50, мс"),
                ("p95_pause_ms", "p95, мс"),
                ("p99_pause_ms", "p99, мс"),
                ("max_pause_ms", "Максимум, мс"),
            ]
            headers = "".join(f"<th>{html.escape(label)}</th>" for _, label in columns)
            body = "".join(
                "<tr>" + "".join(
                    f"<td>{html.escape(item.get(key, ''))}</td>"
                    for key, _ in columns
                ) + "</tr>"
                for item in run_rows
            )
            run_table = (
                f"<details><summary>Показать показатели по отдельным запускам ({len(run_rows)})</summary>"
                f'<div class="table-wrap"><table><thead><tr>{headers}</tr></thead>'
                f"<tbody>{body}</tbody></table></div></details>"
            )

    headers = ("Метрика", "Медиана", "Q1", "Q3", "Единица")
    header_html = "".join(f"<th>{html.escape(label)}</th>" for label in headers)
    return (
        '<section><h2>Java JFR — паузы GC</h2>'
        f'<p>Независимых записей: {html.escape(row.get("runs", ""))}. '
        "Учитываются только верхнеуровневые события "
        "<code>jdk.GCPhasePause</code>; вложенные фазы не суммируются.</p>"
        f'<div class="table-wrap"><table><thead><tr>{header_html}</tr></thead>'
        f"<tbody>{''.join(summary_table_rows)}</tbody></table></div>"
        f"{run_table}</section>"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_file")
    ap.add_argument("-o", "--output-dir", default="results/report")
    ap.add_argument("--split-by-scenario", action="store_true", help="Create a separate report directory for each scenario")
    ap.add_argument("--jfr-analysis-dir", type=Path, help="Directory with JFR CSV summaries from jfr_pause_batch.py")
    args = ap.parse_args()

    source = Path(args.csv_file)
    rows = load_rows(source)
    session_ids = {row.get("session_id") for row in rows if row.get("session_id")}
    if len(session_ids) > 1:
        raise ValueError(
            "The CSV contains multiple experiment sessions. Generate separate reports "
            "per session; do not pool process-level confidence intervals across sessions."
        )
    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)

    if args.split_by_scenario:
        scenarios = sorted({row["scenario"] for row in rows if row.get("scenario")})
        for scenario in scenarios:
            subset = [row for row in rows if row.get("scenario") == scenario]
            scenario_csv = output / f"{scenario}.csv"
            fields = list(rows[0].keys())
            with scenario_csv.open("w", encoding="utf-8-sig", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=fields)
                writer.writeheader()
                writer.writerows(subset)
        for scenario in scenarios:
            subprocess.run([
                sys.executable,
                str(Path(__file__)),
                str(output / f"{scenario}.csv"),
                "-o",
                str(output / scenario),
            ] + (
                ["--jfr-analysis-dir", str(args.jfr_analysis_dir)]
                if args.jfr_analysis_dir else []
            ), check=True)
        links = "".join(
            f'<li><a href="{html.escape(scenario)}/index.html">{html.escape(scenario.title())}</a></li>'
            for scenario in scenarios
        )
        (output / "index.html").write_text(
            '<!doctype html><html lang="ru"><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>GC Benchmark — все сценарии</title>'
            '<style>body{font-family:"Segoe UI",Arial,sans-serif;background:#f4f7fb;color:#172b4d;padding:24px}'
            'main{max-width:900px;margin:auto}ul{display:grid;gap:12px;padding:0;list-style:none}'
            'a{display:block;padding:18px;background:white;border-radius:10px;color:#175cd3;text-decoration:none;font-size:18px;font-weight:600}</style>'
            '<main><h1>GC Benchmark — результаты всех сценариев</h1>'
            f'<ul>{links}</ul></main></html>',
            encoding="utf-8",
        )
        print(f"Created reports for {len(scenarios)} scenarios in {output}")
        return

    configurations = {
        tuple(row.get(field, "") for field in ("items", "batches", "warmup_batches", "payload_bytes"))
        for row in rows
    }
    if len(configurations) > 1:
        raise ValueError(
            "The CSV mixes benchmark parameters. Generate separate reports for each configuration."
        )
    expected_values = {
        int(value) for row in rows
        if (value := row.get("expected_repetitions", "").strip()).isdigit()
    }
    if len(expected_values) > 1:
        raise ValueError("The CSV contains conflicting expected repetition counts.")
    if expected_values:
        expected = next(iter(expected_values))
        observed = {
            platform: sum(row.get("platform") == platform for row in rows)
            for platform in PLATFORM_ORDER
            if any(row.get("platform") == platform for row in rows)
        }
        incomplete = {platform: count for platform, count in observed.items() if count != expected}
        if incomplete:
            details = ", ".join(f"{platform}: {count}/{expected}" for platform, count in incomplete.items())
            raise ValueError(f"Incomplete repetition series; refusing to report it: {details}")

    report_scenarios = {row.get("scenario") for row in rows}
    metrics = METRICS
    if report_scenarios == {"large"}:
        metrics = [
            ("large_buffers_per_second", "Массивов в секунду", "arrays/s"),
            *METRICS[1:],
        ]
    throughput_column, throughput_title, _ = metrics[0]
    throughput_caption = "массивов/с" if throughput_column == "large_buffers_per_second" else "узлов/с"

    for column, title, unit in metrics:
        bar_chart(rows, column, title + " — медиана и IQR", unit, output / (column.replace(".", "_") + ".svg"))

    run_strip(
        rows,
        throughput_column,
        f"{throughput_title} — отдельные повторения",
        output / (throughput_column.replace(".", "_") + "_runs.svg"),
    )

    summary_rows = []
    for column, title, unit in metrics:
        stats = summarize(rows, column)
        for platform, item in stats.items():
            summary_rows.append({
                "Платформа": platform,
                "Показатель": title,
                "Повторов": item["runs"],
                "Среднее": f"{item['mean']:.4f}",
                "Медиана": f"{item['median']:.4f}",
                "Q1": f"{item['q1']:.4f}",
                "Q3": f"{item['q3']:.4f}",
                "95% ДИ медианы": (
                    f"[{item['median_ci95'][0]:.4f}, {item['median_ci95'][1]:.4f}]"
                    if item["median_ci95"] else "недостаточно повторов (нужно ≥6)"
                ),
                "Std": f"{item['std']:.4f}",
                "Минимум": f"{item['min']:.4f}",
                "Максимум": f"{item['max']:.4f}",
                "Единица": unit,
            })

    summary_path = output / "summary.csv"
    with summary_path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(summary_rows[0]))
        writer.writeheader()
        writer.writerows(summary_rows)

    diagnostic_rows = []
    diagnostic_charts = []
    diagnostic_sections = []
    for metric, title, unit, _, note in DIAGNOSTIC_METRICS:
        stats = summarize(rows, metric)
        for platform, item in stats.items():
            diagnostic_rows.append({
                "Платформа": platform,
                "Показатель": title,
                "Повторов": item["runs"],
                "Медиана": f"{item['median']:.4f}",
                "Q1": f"{item['q1']:.4f}",
                "Q3": f"{item['q3']:.4f}",
                "95% ДИ медианы": (
                    f"[{item['median_ci95'][0]:.4f}, {item['median_ci95'][1]:.4f}]"
                    if item["median_ci95"] else "недостаточно повторов (нужно ≥6)"
                ),
                "Единица": unit,
                "Ограничение": note,
            })
            chart_name = f"gc_{metric}_{platform}.svg"
            bar_chart(
                [row for row in rows if row.get("platform") == platform],
                metric,
                f"{title} — {platform}: медиана и IQR",
                unit,
                output / chart_name,
            )
            diagnostic_charts.append(
                f'<section><h3>{html.escape(title)} — {html.escape(platform)}</h3>'
                f'<p>{html.escape(note)}</p><img src="{html.escape(chart_name)}" alt="{html.escape(title)}"></section>'
            )

    java_collector_columns = sorted({
        key for row in rows for key in row
        if key.startswith("gc_collectors_delta.")
        and (key.endswith(".count_delta") or key.endswith(".elapsed_ms_delta"))
    })
    for column in java_collector_columns:
        java_rows = [row for row in rows if row.get("platform") == "java"]
        stats = summarize(java_rows, column)
        collector_metric = column.removeprefix("gc_collectors_delta.")
        collector, _, metric_kind = collector_metric.rpartition(".")
        is_elapsed = metric_kind == "elapsed_ms_delta"
        title = (
            f"Java: elapsed MXBean коллектора {collector}"
            if is_elapsed else f"Java: число коллекций MXBean {collector}"
        )
        unit = "ms (approx)" if is_elapsed else "collections"
        note = (
            "Приблизительное elapsed-время этого коллектора, не STW и не CPU-время; "
            "значения разных коллекторов не суммируются."
            if is_elapsed else
            "Отдельный счётчик MXBean; разные коллекторы не суммируются в общее число циклов."
        )
        for platform, item in stats.items():
            diagnostic_rows.append({
                "Платформа": platform,
                "Показатель": title,
                "Повторов": item["runs"],
                "Медиана": f"{item['median']:.4f}",
                "Q1": f"{item['q1']:.4f}",
                "Q3": f"{item['q3']:.4f}",
                "95% ДИ медианы": (
                    f"[{item['median_ci95'][0]:.4f}, {item['median_ci95'][1]:.4f}]"
                    if item["median_ci95"] else "недостаточно повторов (нужно ≥6)"
                ),
                "Единица": unit,
                "Ограничение": note,
            })
            chart_name = "gc_java_collector_" + "".join(
                character if character.isalnum() else "_" for character in collector
            ) + ".svg"
            bar_chart(
                java_rows,
                column,
                f"{title}: медиана и IQR",
                unit,
                output / chart_name,
            )
            diagnostic_charts.append(
                f'<section><h3>{html.escape(title)}</h3>'
                f'<p>{html.escape(note)}</p><img src="{html.escape(chart_name)}" alt="{html.escape(title)}"></section>'
            )

    diagnostic_path = output / "gc-diagnostics.csv"
    if diagnostic_rows:
        with diagnostic_path.open("w", encoding="utf-8-sig", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(diagnostic_rows[0]))
            writer.writeheader()
            writer.writerows(diagnostic_rows)

    raw_path = output / "all-results.csv"
    with source.open("r", encoding="utf-8-sig", newline="") as f:
        source_reader = csv.DictReader(f)
        source_fields = source_reader.fieldnames or []
        source_rows = list(source_reader)
    with raw_path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=source_fields)
        writer.writeheader()
        writer.writerows(source_rows)

    throughput = summarize(rows, throughput_column)
    baseline = throughput.get("go", {}).get("median", 0)
    cards = (
        "<p>Темп отражает только эту синтетическую нагрузку и не является рейтингом "
        "языков или пропускной способности реального приложения.</p>"
    )

    table_rows = "".join(
        "<tr>" + "".join(f"<td>{html.escape(str(row[field]))}</td>" for field in summary_rows[0]) + "</tr>"
        for row in summary_rows
    )
    headers = "".join(f"<th>{html.escape(field)}</th>" for field in summary_rows[0])
    diagnostic_table_rows = "".join(
        "<tr>" + "".join(f"<td>{html.escape(str(row[field]))}</td>" for field in diagnostic_rows[0]) + "</tr>"
        for row in diagnostic_rows
    ) if diagnostic_rows else ""
    diagnostic_headers = "".join(f"<th>{html.escape(field)}</th>" for field in diagnostic_rows[0]) if diagnostic_rows else ""
    raw_headers = "".join(f"<th>{html.escape(field)}</th>" for field in source_fields)
    raw_table_rows = "".join(
        "<tr>" + "".join(f"<td>{html.escape(row.get(field, ''))}</td>" for field in source_fields) + "</tr>"
        for row in source_rows
    )
    chart_cards = "".join(
        f'<section><h2>{html.escape(title)}</h2><img src="{html.escape(column.replace(".", "_") + ".svg")}" alt="{html.escape(title)}"></section>'
        for column, title, _ in metrics
    )

    scenario_values = sorted({row["scenario"] for row in rows if row.get("scenario")})
    report_scenario = scenario_values[0] if len(scenario_values) == 1 else ", ".join(scenario_values)
    jfr_section = "".join(
        jfr_report_section(scenario, args.jfr_analysis_dir)
        for scenario in scenario_values
    ) if args.jfr_analysis_dir else ""
    html_text = f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>GC benchmark report</title><style>
body{{font-family:"Segoe UI",Arial,sans-serif;margin:0;background:#f4f7fb;color:#172b4d}}
main{{max-width:1200px;margin:auto;padding:24px}}
h1,h2{{margin-bottom:12px}}.cards{{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}}.card{{background:white;border-radius:12px;padding:18px;box-shadow:0 2px 8px #0001}}.platform{{font-size:18px;font-weight:600}}.value{{font-size:30px;font-weight:700;margin:8px 0}}.delta{{color:#596}}
section{{background:white;border-radius:12px;margin:16px 0;padding:16px;box-shadow:0 2px 8px #0001}}img{{width:100%;height:auto}}table{{width:100%;border-collapse:collapse;background:white}}th,td{{padding:9px;border-bottom:1px solid #dfe5ec;text-align:right}}th:first-child,td:first-child,th:nth-child(2),td:nth-child(2){{text-align:left}}
.table-wrap{{overflow:auto;background:white;border-radius:12px;box-shadow:0 2px 8px #0001}}footer{{color:#667;margin-top:24px}}
</style></head><body><main>
<h1>Отчёт GC benchmark: {html.escape(report_scenario)}</h1>
<div class="cards">{cards}</div>
{chart_cards}
<section><h2>Разброс повторений: {html.escape(throughput_title.lower())}</h2><img src="{html.escape(throughput_column.replace('.', '_') + '_runs.svg')}" alt="Повторения: {html.escape(throughput_title.lower())}"></section>
{jfr_section}
<section><h2>Сводная таблица</h2><div class="table-wrap"><table><thead><tr>{headers}</tr></thead><tbody>{table_rows}</tbody></table></div></section>
<section><h2>Диагностика GC по платформам</h2><p>Счётчики поколений .NET, циклов Go и отдельные MXBean-коллекторы Java показаны раздельно и не являются общей межплатформенной шкалой. Паузы Go/.NET и JFR Java также получены разными способами и не сравниваются как эквивалентные распределения. Скорость аллокаций у Go/.NET процессная, у Java — только поток теста.</p><div class="table-wrap"><table><thead><tr>{diagnostic_headers}</tr></thead><tbody>{diagnostic_table_rows}</tbody></table></div>{''.join(diagnostic_charts)}</section>
<section><h2>Все результаты</h2><div class="table-wrap full-table"><table><thead><tr>{raw_headers}</tr></thead><tbody>{raw_table_rows}</tbody></table></div></section>
<footer>Источник: {html.escape(str(source))}. Session ID: {html.escape(', '.join(sorted(session_ids)) if session_ids else 'не указан')}. Столбцы показывают медиану, усы — Q1–Q3 (PERCENTILE.INC). 95% ДИ медианы — точный консервативный непараметрический интервал по порядковым статистикам независимых процессных повторов; он показывается только при n ≥ 6. Он описывает вариацию запусков внутри одной сессии, но не межсессионный дрейф; для публикационных выводов повторите полный эксперимент отдельными сессиями. Интервалы пауз JFR не заменяют независимые запуски бенчмарка.</footer>
</main></body></html>"""
    (output / "index.html").write_text(html_text, encoding="utf-8")
    print(f"Created {output / 'index.html'}")
    print(f"Created {summary_path}")
    print(f"Created {raw_path}")


if __name__ == "__main__":
    main()
