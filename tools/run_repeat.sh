#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <go|dotnet|java> <scenario> [runs=10] [items=10000] [batches=1000] [payload=128]" >&2
  exit 2
fi
platform="$1"
scenario="$2"
runs="${3:-10}"
items="${4:-10000}"
batches="${5:-1000}"
payload="${6:-128}"
warmup="${WARMUP_BATCHES:-50}"
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/results"
out="$root/results/${platform}-${scenario}.jsonl"
: > "$out"

case "$platform" in
  go)
    (cd "$root/go" && go build -o gcbench .)
    for ((i=1; i<=runs; i++)); do
      (cd "$root/go" && ./gcbench -scenario "$scenario" -warmup-batches "$warmup" -batches "$batches" -items "$items" -payload "$payload") >> "$out"
    done
    ;;
  dotnet)
    if ! dotnet --list-sdks | grep -qE '^10\.'; then
      echo "ERROR: .NET 10 SDK was not found. Install the .NET 10 SDK." >&2
      dotnet --list-sdks >&2 || true
      exit 1
    fi
    (cd "$root/dotnet/GC.Bench" && dotnet build -c Release --nologo)
    dll="$root/dotnet/GC.Bench/bin/Release/net10.0/GC.Bench.dll"
    for ((i=1; i<=runs; i++)); do
      dotnet "$dll" --scenario "$scenario" --warmup-batches "$warmup" --batches "$batches" --items "$items" --payload "$payload" >> "$out"
    done
    ;;
  java)
    (cd "$root/java" && javac GcBench.java)
    # JAVA_OPTS may be used to pin heap size or select a collector for a separate series.
    read -r -a java_opts <<< "${JAVA_OPTS:-}"
    for ((i=1; i<=runs; i++)); do
      (cd "$root/java" && java "${java_opts[@]}" GcBench --scenario "$scenario" --warmup-batches "$warmup" --batches "$batches" --items "$items" --payload "$payload") >> "$out"
    done
    ;;
  *)
    echo "Unknown platform: $platform" >&2
    exit 2
    ;;
esac

echo "Saved $runs runs to $out"
