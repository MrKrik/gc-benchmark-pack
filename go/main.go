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
			}
			if n.Left != nil {
				checksum += uint64(n.Left.ID)
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

func pauseSamples(after runtime.MemStats, delta uint32) []float64 {
	count := delta
	if count > 256 {
		count = 256
	}
	out := make([]float64, 0, count)
	for i := uint32(0); i < count; i++ {
		idx := (after.NumGC + 255 - i) % 256
		ns := after.PauseNs[idx]
		if ns > 0 {
			out = append(out, float64(ns)/1e6)
		}
	}
	return out
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
	warmupBatches := flag.Int("warmup-batches", 10, "unmeasured warm-up batches")
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
	warmItems := *items
	for b := 0; b < *warmupBatches; b++ {
		switch *scenario {
		case "large":
			sinkBytes = make([][]byte, warmItems)
			for i := range sinkBytes {
				sinkBytes[i] = make([]byte, *payload)
			}
			sinkBytes = nil
		default:
			sinkNodes = makeNodes(warmItems, *payload, *scenario == "graph")
			touchNodes(sinkNodes)
			sinkNodes = nil
		}
	}
	retainedNodes = nil
	sinkNodes = nil
	sinkBytes = nil
	// A forced full collection is part of the unmeasured warm-up/reset phase.
	runtime.GC()
	retainCount := max(1, *items/10)
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
	runtime.KeepAlive(retainedNodes)
	runtime.GC()
	var afterFullGC runtime.MemStats
	runtime.ReadMemStats(&afterFullGC)
	pauseDelta := after.PauseTotalNs - before.PauseTotalNs
	gcDelta := after.NumGC - before.NumGC
	pauses := pauseSamples(after, gcDelta)
	logicalNodesPerSecond := float64(nodesCreated) / elapsedSeconds
	payloadBytesPerSecond := float64(payloadRequested) / elapsedSeconds
	allocatedBytesPerSecond := float64(after.TotalAlloc-before.TotalAlloc) / elapsedSeconds

	p50, p95, p99 := percentile(batchTimes, .50), percentile(batchTimes, .95), percentile(batchTimes, .99)
	out := map[string]any{
		"platform": "go", "runtime_version": runtime.Version(), "goos": runtime.GOOS, "goarch": runtime.GOARCH,
		"session_id": os.Getenv("GC_BENCH_SESSION_ID"), "repetition": os.Getenv("GC_BENCH_REPETITION"),
		"run_order":            os.Getenv("GC_BENCH_RUN_ORDER"),
		"expected_repetitions": os.Getenv("GC_BENCH_EXPECTED_REPETITIONS"),
		"scenario":             *scenario, "batches": *batches, "warmup_batches": *warmupBatches, "items": *items, "payload_bytes": *payload,
		"objects_created_nodes": nodesCreated, "retained_nodes_after": len(retainedNodes), "large_buffers_created": largeBuffers, "payload_bytes_requested": payloadRequested,
		"elapsed_ms":                 elapsedSeconds * 1000,
		"logical_nodes_per_second":   logicalNodesPerSecond,
		"payload_bytes_per_second":   payloadBytesPerSecond,
		"allocated_bytes_per_second": allocatedBytesPerSecond,
		"batch_latency_ms":           map[string]any{"p50": p50, "p95": p95, "p99": p99, "samples": len(batchTimes), "timer": batchTimerName},
		"metrics": map[string]any{
			"allocated_bytes_delta":  after.TotalAlloc - before.TotalAlloc,
			"heap_alloc_bytes_after": after.HeapAlloc, "heap_sys_bytes_after": after.HeapSys,
			"heap_inuse_bytes_after": after.HeapInuse, "heap_objects_after": after.HeapObjects,
			"heap_live_bytes_after_full_gc": afterFullGC.HeapAlloc, "heap_objects_after_full_gc": afterFullGC.HeapObjects,
			"sys_bytes_after": after.Sys, "heap_released_bytes_after": after.HeapReleased,
			"gc_cycles_delta": gcDelta, "gc_stw_pause_total_ms_delta": float64(pauseDelta) / 1e6,
			"recent_gc_pause_ms":                 map[string]any{"p50": percentile(pauses, .50), "p95": percentile(pauses, .95), "max": maxFloat(pauses), "samples": len(pauses)},
			"gc_cpu_fraction_process_cumulative": after.GCCPUFraction,
			"gc_cpu_seconds_estimated_delta":     gcCPUAfter - gcCPUBefore,
		},
		"checksum": checksum,
		"note":     "Go GC CPU-seconds is an estimated runtime metric; GCCPUFraction is process-cumulative; recent pause samples cover at most the last 256 GC cycles.",
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

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
