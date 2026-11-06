package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"runtime"
	"runtime/metrics"
	"sort"
)

type Node struct {
	ID      int64
	Left    *Node
	Right   *Node
	Payload []byte
}

var sinkNodes []*Node
var sinkBytes [][]byte
var retainedNodes []*Node
var checksum uint64

func makeNodes(n, payload int, graph bool) []*Node {
	if n < 0 {
		n = 0
	}
	nodes := make([]*Node, n)
	for i := 0; i < n; i++ {
		nodes[i] = &Node{ID: int64(i), Payload: make([]byte, payload)}
		if payload > 0 {
			nodes[i].Payload[0] = byte(i)
			nodes[i].Payload[payload-1] = byte(i >> 8)
		}
	}
	if graph && n > 1 {
		for i := range nodes {
			nodes[i].Left = nodes[(i+1)%n]
			nodes[i].Right = nodes[(i*17+7)%n]
		}
	}
	return nodes
}

func touchNodes(nodes []*Node) {
	for _, n := range nodes {
		if n != nil {
			checksum += uint64(n.ID) + uint64(len(n.Payload))
			if len(n.Payload) > 0 {
				checksum += uint64(n.Payload[0])
				checksum += uint64(n.Payload[len(n.Payload)-1])
			}
			if n.Left != nil {
				checksum += uint64(n.Left.ID)
			}
			if n.Right != nil {
				checksum += uint64(n.Right.ID)
			}
		}
	}
}

func percentile(values []float64, p float64) *float64 {
	if len(values) == 0 {
		return nil
	}
	v := append([]float64(nil), values...)
	sort.Float64s(v)
	position := float64(len(v)-1) * p
	lower := int(position)
	upper := minInt(lower+1, len(v)-1)
	fraction := position - float64(lower)
	x := v[lower] + (v[upper]-v[lower])*fraction
	return &x
}

type pauseHistogram struct {
	buckets []float64
	counts  []uint64
}

func readPauseHistogram() (pauseHistogram, error) {
	sample := []metrics.Sample{{Name: "/sched/pauses/total/gc:seconds"}}
	metrics.Read(sample)
	if sample[0].Value.Kind() != metrics.KindFloat64Histogram {
		return pauseHistogram{}, fmt.Errorf("/sched/pauses/total/gc:seconds has unexpected value kind %v", sample[0].Value.Kind())
	}
	histogram := sample[0].Value.Float64Histogram()
	if histogram == nil {
		return pauseHistogram{}, fmt.Errorf("/sched/pauses/total/gc:seconds returned an empty histogram")
	}
	return pauseHistogram{
		buckets: append([]float64(nil), histogram.Buckets...),
		counts:  append([]uint64(nil), histogram.Counts...),
	}, nil
}

func pauseHistogramDelta(before, after pauseHistogram) ([]float64, []map[string]any, error) {
	if len(before.counts) != len(after.counts) || len(after.buckets) != len(after.counts)+1 {
		return nil, nil, fmt.Errorf("incompatible /sched/pauses/total/gc:seconds histogram snapshots")
	}
	var values []float64
	buckets := make([]map[string]any, 0, len(after.counts))
	for i, count := range after.counts {
		if count < before.counts[i] {
			return nil, nil, fmt.Errorf("/sched/pauses/total/gc:seconds histogram counter decreased at bucket %d", i)
		}
		delta := count - before.counts[i]
		if delta == 0 {
			continue
		}
		lower, upper := after.buckets[i], after.buckets[i+1]
		var lowerBound, upperBound any = lower, upper
		if lower < -1e300 {
			lowerBound = nil
		}
		if upper > 1e300 {
			upperBound = nil
		}
		buckets = append(buckets, map[string]any{
			"lower_bound_seconds": lowerBound,
			"upper_bound_seconds": upperBound,
			"count":               delta,
		})
		estimate := upper
		switch {
		case lower >= 0 && upper >= 0 && upper < 1e300:
			estimate = lower + (upper-lower)/2
		case lower > 0 && upper >= 1e300:
			estimate = lower
		}
		for n := uint64(0); n < delta; n++ {
			values = append(values, estimate*1000)
		}
	}
	return values, buckets, nil
}

func readGCCPUSeconds() float64 {
	s := []metrics.Sample{{Name: "/cpu/classes/gc/total:cpu-seconds"}}
	metrics.Read(s)
	if s[0].Value.Kind() == metrics.KindFloat64 {
		return s[0].Value.Float64()
	}
	return 0
}

func main() {
	scenario := flag.String("scenario", "transient", "transient|retained|graph|large|mixed")
	batches := flag.Int("batches", 1000, "number of measured batches")
	warmupBatches := flag.Int("warmup-batches", 50, "unmeasured warm-up batches")
	items := flag.Int("items", 10000, "items per batch or retained-set size")
	payload := flag.Int("payload", 128, "payload bytes per node; for large scenario, bytes per array")
	flag.Parse()
	if *batches < 1 || *warmupBatches < 0 || *items < 1 || *payload < 0 {
		fmt.Fprintln(os.Stderr, "batches and items must be positive; warm-up batches and payload must be non-negative")
		os.Exit(2)
	}
	switch *scenario {
	case "transient", "retained", "graph", "large", "mixed":
	default:
		fmt.Fprintln(os.Stderr, "unknown scenario:", *scenario)
		os.Exit(2)
	}

	retainedNodes = nil
	sinkNodes = nil
	sinkBytes = nil
	retainCount := max(1, *items/10)
	if *scenario == "retained" || *scenario == "mixed" {
		if *warmupBatches > int(^uint(0)>>1)/retainCount {
			fmt.Fprintln(os.Stderr, "warm-up retained node capacity exceeds the supported size")
			os.Exit(2)
		}
		retainedNodes = make([]*Node, 0, retainCount*(*warmupBatches))
	}
	for b := 0; b < *warmupBatches; b++ {
		switch *scenario {
		case "large":
			sinkBytes = make([][]byte, *items)
			for i := range sinkBytes {
				sinkBytes[i] = make([]byte, *payload)
				if *payload > 0 {
					sinkBytes[i][0] = byte(i)
				}
			}
			if len(sinkBytes) > 0 && len(sinkBytes[0]) > 0 {
				checksum += uint64(sinkBytes[0][0])
			}
			sinkBytes = nil
		case "retained":
			batch := makeNodes(*items, *payload, false)
			for i := 0; i < retainCount; i++ {
				retainedNodes = append(retainedNodes, batch[i*len(batch)/retainCount])
			}
			sinkNodes = batch
			touchNodes(sinkNodes)
			sinkNodes = nil
		case "mixed":
			batch := makeNodes(*items, *payload, false)
			for i := 0; i < retainCount; i++ {
				retainedNodes = append(retainedNodes, batch[i*len(batch)/retainCount])
			}
			sinkNodes = batch
			touchNodes(sinkNodes)
			sinkBytes = [][]byte{make([]byte, max(1, *payload*16))}
			checksum += uint64(sinkBytes[0][0])
			sinkNodes = nil
			sinkBytes = nil
		default:
			sinkNodes = makeNodes(*items, *payload, *scenario == "graph")
			touchNodes(sinkNodes)
			sinkNodes = nil
		}
	}
	retainedNodes = nil
	sinkNodes = nil
	sinkBytes = nil
	// A forced full collection is part of the unmeasured warm-up/reset phase.
	runtime.GC()
	if *batches > int(^uint(0)>>1)/retainCount {
		fmt.Fprintln(os.Stderr, "retained node capacity exceeds the supported size")
		os.Exit(2)
	}
	if *scenario == "retained" || *scenario == "mixed" {
		retainedCapacity := retainCount * (*batches)
		retainedNodes = make([]*Node, 0, retainedCapacity)
	}
	var before, after runtime.MemStats
	batchNow, batchFrequency, batchTimerName, err := newBatchTimer()
	if err != nil {
		fmt.Fprintln(os.Stderr, "initialize high-resolution batch timer:", err)
		os.Exit(2)
	}
	gcCPUBefore := readGCCPUSeconds()
	runtime.ReadMemStats(&before)
	pauseHistogramBefore, err := readPauseHistogram()
	if err != nil {
		fmt.Fprintln(os.Stderr, "read GC pause histogram before measurement:", err)
		os.Exit(2)
	}
	batchTimes := make([]float64, 0, *batches)
	var nodesCreated, largeBuffers uint64
	var payloadRequested uint64
	start, err := batchNow()
	if err != nil {
		fmt.Fprintln(os.Stderr, "read high-resolution measurement timer:", err)
		os.Exit(2)
	}

	for b := 0; b < *batches; b++ {
		bs, err := batchNow()
		if err != nil {
			fmt.Fprintln(os.Stderr, "read high-resolution batch timer:", err)
			os.Exit(2)
		}
		switch *scenario {
		case "transient":
			sinkNodes = makeNodes(*items, *payload, false)
			nodesCreated += uint64(*items)
			payloadRequested += uint64(*items) * uint64(*payload)
			touchNodes(sinkNodes)
			sinkNodes = nil
		case "retained":
			batch := makeNodes(*items, *payload, false)
			for i := 0; i < retainCount; i++ {
				retainedNodes = append(retainedNodes, batch[i*len(batch)/retainCount])
			}
			sinkNodes = batch
			nodesCreated += uint64(*items)
			payloadRequested += uint64(*items) * uint64(*payload)
			touchNodes(sinkNodes)
			sinkNodes = nil
		case "graph":
			sinkNodes = makeNodes(*items, *payload, true)
			nodesCreated += uint64(*items)
			payloadRequested += uint64(*items) * uint64(*payload)
			touchNodes(sinkNodes)
			sinkNodes = nil
		case "large":
			sinkBytes = make([][]byte, *items)
			for i := range sinkBytes {
				sinkBytes[i] = make([]byte, *payload)
				if *payload > 0 {
					sinkBytes[i][0] = byte(i)
				}
			}
			largeBuffers += uint64(*items)
			payloadRequested += uint64(*items) * uint64(*payload)
			if len(sinkBytes) > 0 && len(sinkBytes[0]) > 0 {
				checksum += uint64(sinkBytes[0][0])
			}
			sinkBytes = nil
		case "mixed":
			batch := makeNodes(*items, *payload, false)
			keepCount := max(1, *items/10)
			for i := 0; i < keepCount; i++ {
				retainedNodes = append(retainedNodes, batch[i*len(batch)/keepCount])
			}
			sinkNodes = batch
			touchNodes(sinkNodes)
			nodesCreated += uint64(*items)
			payloadRequested += uint64(*items) * uint64(*payload)
			sinkBytes = [][]byte{make([]byte, max(1, *payload*16))}
			largeBuffers++
			payloadRequested += uint64(max(1, *payload*16))
			if len(sinkBytes[0]) > 0 {
				checksum += uint64(sinkBytes[0][0])
			}
			sinkNodes = nil
			sinkBytes = nil
		}
		be, err := batchNow()
		if err != nil {
			fmt.Fprintln(os.Stderr, "read high-resolution batch timer:", err)
			os.Exit(2)
		}
		if be < bs {
			fmt.Fprintln(os.Stderr, "high-resolution timer moved backwards during a batch")
			os.Exit(2)
		}
		batchTimes = append(batchTimes, float64(be-bs)*1000/float64(batchFrequency))
	}
	end, err := batchNow()
	if err != nil {
		fmt.Fprintln(os.Stderr, "read high-resolution measurement timer:", err)
		os.Exit(2)
	}
	if end <= start {
		fmt.Fprintln(os.Stderr, "measurement interval was too short to measure; increase items or batches")
		os.Exit(2)
	}
	elapsedSeconds := float64(end-start) / float64(batchFrequency)
	runtime.ReadMemStats(&after)
	gcCPUAfter := readGCCPUSeconds()
	pauseHistogramAfter, err := readPauseHistogram()
	if err != nil {
		fmt.Fprintln(os.Stderr, "read GC pause histogram after measurement:", err)
		os.Exit(2)
	}
	runtime.KeepAlive(retainedNodes)
	runtime.GC()
	var afterFullGC runtime.MemStats
	runtime.ReadMemStats(&afterFullGC)
	pauseDelta := after.PauseTotalNs - before.PauseTotalNs
	gcDelta := after.NumGC - before.NumGC
	pauses, pauseBuckets, err := pauseHistogramDelta(pauseHistogramBefore, pauseHistogramAfter)
	if err != nil {
		fmt.Fprintln(os.Stderr, "calculate GC pause histogram delta:", err)
		os.Exit(2)
	}
	logicalNodesPerSecond := float64(nodesCreated) / elapsedSeconds
	payloadBytesPerSecond := float64(payloadRequested) / elapsedSeconds
	allocatedBytesPerSecond := float64(after.TotalAlloc-before.TotalAlloc) / elapsedSeconds

	p50, p95, p99 := percentile(batchTimes, .50), percentile(batchTimes, .95), percentile(batchTimes, .99)
	out := map[string]any{
		"schema_version": 2,
		"metric_definitions": map[string]any{
			"allocated_bytes_delta": map[string]any{"unit": "bytes", "source": "runtime.MemStats.TotalAlloc", "scope": "go_runtime_process", "calculation": "TotalAlloc_after - TotalAlloc_before", "cross_platform_comparable": false},
			"allocated_bytes_per_second": map[string]any{"unit": "bytes/s", "source": "runtime.MemStats.TotalAlloc", "scope": "go_runtime_process", "calculation": "allocated_bytes_delta / elapsed_seconds", "cross_platform_comparable": false},
			"gc_cycles_delta":       map[string]any{"unit": "cycles", "source": "runtime.MemStats.NumGC", "scope": "measured_interval", "calculation": "NumGC_after - NumGC_before; complete Go GC cycles", "cross_platform_comparable": false},
			"gc_pause_percentiles":  map[string]any{"unit": "ms", "source": "/sched/pauses/total/gc:seconds", "scope": "measured_interval", "calculation": "approximate quantiles from histogram bucket deltas", "cross_platform_comparable": false},
		},
		"platform": "go", "runtime_configuration_id": "default",
		"gc_configuration": map[string]any{
			"GOGC":                envOrDefault("GOGC", "100 (runtime default)"),
			"GOMEMLIMIT":          envOrDefault("GOMEMLIMIT", "unlimited (runtime default)"),
			"GOMAXPROCS_env":      envOrDefault("GOMAXPROCS", "unset"),
			"GOMAXPROCS_effective": runtime.GOMAXPROCS(0),
			"available_logical_cpus": runtime.NumCPU(),
		},
		"runtime_version": runtime.Version(), "goos": runtime.GOOS, "goarch": runtime.GOARCH,
		"session_id": os.Getenv("GC_BENCH_SESSION_ID"), "repetition": os.Getenv("GC_BENCH_REPETITION"),
		"run_order":            os.Getenv("GC_BENCH_RUN_ORDER"),
		"expected_repetitions": os.Getenv("GC_BENCH_EXPECTED_REPETITIONS"),
		"scenario":             *scenario, "batches": *batches, "warmup_batches": *warmupBatches, "items": *items, "payload_bytes": *payload,
		"objects_created_nodes": nodesCreated, "retained_nodes_after": len(retainedNodes), "large_buffers_created": largeBuffers, "payload_bytes_requested": payloadRequested,
		"elapsed_ms":                 elapsedSeconds * 1000,
		"logical_nodes_per_second":   logicalNodesPerSecond,
		"payload_bytes_per_second":   payloadBytesPerSecond,
		"allocated_bytes_per_second": allocatedBytesPerSecond,
		"allocated_bytes_scope":      "go_runtime_process",
		"batch_latency_ms":           map[string]any{"p50": p50, "p95": p95, "p99": p99, "samples": len(batchTimes), "timer": batchTimerName},
		"metrics": map[string]any{
			"allocated_bytes_delta":  after.TotalAlloc - before.TotalAlloc,
			"heap_alloc_bytes_after": after.HeapAlloc, "heap_sys_bytes_after": after.HeapSys,
			"heap_inuse_bytes_after": after.HeapInuse, "heap_objects_after": after.HeapObjects,
			"heap_live_bytes_after_full_gc": afterFullGC.HeapAlloc, "heap_objects_after_full_gc": afterFullGC.HeapObjects,
			"sys_bytes_after": after.Sys, "heap_released_bytes_after": after.HeapReleased,
			"gc_cycles_delta": gcDelta, "gc_stw_pause_total_ms_delta": float64(pauseDelta) / 1e6,
			"gc_pause_duration_histogram_ms": map[string]any{
				"p50_approx": percentile(pauses, .50), "p95_approx": percentile(pauses, .95), "p99_approx": percentile(pauses, .99),
				"max_approx": maxFloat(pauses), "samples": len(pauses), "buckets": pauseBuckets,
			},
			"gc_cpu_fraction_process_cumulative": after.GCCPUFraction,
			"gc_cpu_seconds_estimated_delta":     gcCPUAfter - gcCPUBefore,
		},
		"checksum": checksum,
		"note":     "Go GC CPU-seconds is an estimated runtime metric; GCCPUFraction is process-cumulative. GC pause percentiles are approximated from /sched/pauses/total/gc:seconds histogram bucket deltas for the full measurement interval; bucket boundaries do not provide exact per-pause durations.",
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		panic(err)
	}
}

func maxFloat(v []float64) *float64 {
	if len(v) == 0 {
		return nil
	}
	m := v[0]
	for _, x := range v[1:] {
		if x > m {
			m = x
		}
	}
	return &m
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func envOrDefault(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok && value != "" {
		return value
	}
	return fallback
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
