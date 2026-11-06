using System.Diagnostics;
using System.Diagnostics.Tracing;
using System.Runtime;
using System.Text.Json;

sealed class Node
{
    public long Id;
    public Node? Left;
    public Node? Right;
    public byte[] Payload = Array.Empty<byte>();
}

[EventSource(Name = "GC.Bench")]
public sealed class BenchmarkTrace : EventSource
{
    public static readonly BenchmarkTrace Log = new();

    [Event(1, Level = EventLevel.Informational)]
    public void MeasurementStart() => WriteEvent(1);

    [Event(2, Level = EventLevel.Informational)]
    public void MeasurementEnd() => WriteEvent(2);
}

static class Program
{
    private static volatile Node[]? _sinkNodes;
    private static volatile byte[][]? _sinkBytes;
    private static readonly List<Node> Retained = new();
    private static ulong _checksum;

    private sealed record Snapshot(long Allocated, long HeapUsed, long HeapCommitted,
        TimeSpan PauseTotal, int Gen0, int Gen1, int Gen2, double PausePercent,
        long FragmentedBytes, long WorkingSet);

    private static Node[] MakeNodes(int count, int payload, bool graph)
    {
        var nodes = new Node[count];
        for (int i = 0; i < count; i++)
        {
            var data = new byte[payload];
            if (payload > 0)
            {
                data[0] = (byte)i;
                data[payload - 1] = (byte)(i >> 8);
            }
            nodes[i] = new Node { Id = i, Payload = data };
        }
        if (graph && count > 1)
        {
            for (int i = 0; i < count; i++)
            {
                nodes[i].Left = nodes[(i + 1) % count];
                nodes[i].Right = nodes[(i * 17 + 7) % count];
            }
        }
        return nodes;
    }

    private static void Touch(Node[] nodes)
    {
        foreach (var n in nodes)
        {
            _checksum += (ulong)n.Id + (ulong)n.Payload.Length;
            if (n.Payload.Length > 0)
            {
                _checksum += n.Payload[0];
                _checksum += n.Payload[^1];
            }
            if (n.Left is not null) _checksum += (ulong)n.Left.Id;
            if (n.Right is not null) _checksum += (ulong)n.Right.Id;
        }
    }

    private static void TouchRetained()
    {
        foreach (var n in Retained)
        {
            _checksum += (ulong)n.Id + (ulong)n.Payload.Length;
            if (n.Payload.Length > 0)
            {
                _checksum += n.Payload[0];
                _checksum += n.Payload[^1];
            }
            if (n.Left is not null) _checksum += (ulong)n.Left.Id;
            if (n.Right is not null) _checksum += (ulong)n.Right.Id;
        }
    }

    private static Snapshot ReadSnapshot()
    {
        var allocated = GC.GetTotalAllocatedBytes(precise: false);
        var info = GC.GetGCMemoryInfo(GCKind.Any);
        using var process = Process.GetCurrentProcess();
        process.Refresh();
        return new Snapshot(
            allocated,
            GC.GetTotalMemory(forceFullCollection: false),
            info.TotalCommittedBytes,
            GC.GetTotalPauseDuration(),
            GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2),
            info.PauseTimePercentage, info.FragmentedBytes, process.WorkingSet64);
    }

    private static double? Percentile(List<double> values, double p)
    {
        if (values.Count == 0) return null;
        var sorted = values.Order().ToArray();
        double position = (sorted.Length - 1) * p;
        int lower = (int)Math.Floor(position);
        int upper = Math.Min(lower + 1, sorted.Length - 1);
        double fraction = position - lower;
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction;
    }

    private static object? Run(string[] args)
    {
        string scenario = "transient";
        int batches = 1000, warmupBatches = 50, items = 10000, payload = 128;
        bool diagnosticMarkers = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--diagnostic-markers")
            {
                diagnosticMarkers = true;
                continue;
            }
            string value = (i + 1 < args.Length) ? args[++i] : throw new ArgumentException("Missing argument value");
            switch (args[i - 1])
            {
                case "--scenario": scenario = value; break;
                case "--batches": batches = int.Parse(value); break;
                case "--warmup-batches": warmupBatches = int.Parse(value); break;
                case "--items": items = int.Parse(value); break;
                case "--payload": payload = int.Parse(value); break;
                default: throw new ArgumentException($"Unknown argument: {args[i - 1]}");
            }
        }
        if (batches < 1 || warmupBatches < 0 || items < 1 || payload < 0) throw new ArgumentOutOfRangeException("batches/items must be positive and payload non-negative");
        if (scenario is not ("transient" or "retained" or "graph" or "large" or "mixed")) throw new ArgumentException("Unknown scenario");

        Retained.Clear(); _sinkNodes = null; _sinkBytes = null;
        int retainedPerBatch = Math.Max(1, items / 10);
        int warmItems = items;
        if (scenario is "retained" or "mixed")
            Retained.EnsureCapacity(checked(retainedPerBatch * warmupBatches));
        for (int b = 0; b < warmupBatches; b++)
        {
            switch (scenario)
            {
                case "retained":
                {
                    var batch = MakeNodes(warmItems, payload, false);
                    for (int i = 0; i < retainedPerBatch; i++)
                        Retained.Add(batch[(int)((long)i * warmItems / retainedPerBatch)]);
                    _sinkNodes = batch;
                    Touch(_sinkNodes);
                    _sinkNodes = null;
                    break;
                }
                case "mixed":
                {
                    var batch = MakeNodes(warmItems, payload, false);
                    for (int i = 0; i < retainedPerBatch; i++)
                        Retained.Add(batch[(int)((long)i * warmItems / retainedPerBatch)]);
                    _sinkNodes = batch;
                    Touch(_sinkNodes);
                    _sinkBytes = new[] { new byte[Math.Max(1, checked(payload * 16))] };
                    _checksum += _sinkBytes[0][0];
                    _sinkNodes = null;
                    _sinkBytes = null;
                    break;
                }
                case "large":
                    _sinkBytes = new byte[warmItems][];
                    for (int i = 0; i < warmItems; i++)
                    {
                        _sinkBytes[i] = new byte[payload];
                        if (payload > 0) _sinkBytes[i][0] = (byte)i;
                    }
                    if (_sinkBytes.Length > 0 && _sinkBytes[0].Length > 0) _checksum += _sinkBytes[0][0];
                    _sinkBytes = null;
                    break;
                default:
                    _sinkNodes = MakeNodes(warmItems, payload, scenario == "graph");
                    Touch(_sinkNodes);
                    _sinkNodes = null;
                    break;
            }
        }
        Retained.Clear(); _sinkNodes = null; _sinkBytes = null;
        // Warm-up and explicit compacting full GC are excluded from measured deltas.
        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        if (scenario is "retained" or "mixed")
        {
            Retained.EnsureCapacity(checked(retainedPerBatch * batches));
        }
        var before = ReadSnapshot();
        var batchTimes = new List<double>(batches);
        long nodesCreated = 0, largeBuffers = 0, payloadRequested = 0;
        if (diagnosticMarkers)
        {
            BenchmarkTrace.Log.MeasurementStart();
        }
        var total = Stopwatch.StartNew();

        for (int b = 0; b < batches; b++)
        {
            var sw = Stopwatch.StartNew();
            switch (scenario)
            {
                case "transient":
                    _sinkNodes = MakeNodes(items, payload, false);
                    nodesCreated += items; payloadRequested += (long)items * payload;
                    Touch(_sinkNodes);
                    _sinkNodes = null;
                    break;
                case "retained":
                    var retainedBatch = MakeNodes(items, payload, false);
                    for (int i = 0; i < retainedPerBatch; i++)
                        Retained.Add(retainedBatch[(int)((long)i * items / retainedPerBatch)]);
                    _sinkNodes = retainedBatch;
                    nodesCreated += items; payloadRequested += (long)items * payload;
                    Touch(_sinkNodes);
                    _sinkNodes = null;
                    break;
                case "graph":
                    _sinkNodes = MakeNodes(items, payload, true);
                    nodesCreated += items; payloadRequested += (long)items * payload;
                    Touch(_sinkNodes);
                    _sinkNodes = null;
                    break;
                case "large":
                    _sinkBytes = new byte[items][];
                    for (int i = 0; i < items; i++)
                    {
                        _sinkBytes[i] = new byte[payload];
                        if (payload > 0) _sinkBytes[i][0] = (byte)i;
                    }
                    largeBuffers += items; payloadRequested += (long)items * payload;
                    if (_sinkBytes.Length > 0 && _sinkBytes[0].Length > 0) _checksum += _sinkBytes[0][0];
                    _sinkBytes = null;
                    break;
                case "mixed":
                    var batch = MakeNodes(items, payload, false);
                    int keepCount = Math.Max(1, items / 10);
                    for (int i = 0; i < keepCount; i++) Retained.Add(batch[(int)((long)i * items / keepCount)]);
                    _sinkNodes = batch;
                    Touch(_sinkNodes);
                    nodesCreated += items; payloadRequested += (long)items * payload;
                    _sinkBytes = new[] { new byte[Math.Max(1, checked(payload * 16))] };
                    largeBuffers++; payloadRequested += Math.Max(1, (long)payload * 16);
                    _checksum += _sinkBytes[0][0];
                    _sinkNodes = null; _sinkBytes = null;
                    break;
            }
            sw.Stop();
            batchTimes.Add(sw.Elapsed.TotalMilliseconds);
        }
        total.Stop();
        if (diagnosticMarkers) BenchmarkTrace.Log.MeasurementEnd();
        GC.KeepAlive(Retained);
        GC.KeepAlive(_sinkNodes);
        GC.KeepAlive(_sinkBytes);
        var after = ReadSnapshot();
        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        GC.KeepAlive(Retained);
        var afterFullGc = ReadSnapshot();

        var result = new
        {
            schema_version = 2,
            metric_definitions = new
            {
                allocated_bytes_delta = new { unit = "bytes", source = "GC.GetTotalAllocatedBytes(precise: false)", scope = "dotnet_managed_process", calculation = "counter_after - counter_before", cross_platform_comparable = false },
                allocated_bytes_per_second = new { unit = "bytes/s", source = "GC.GetTotalAllocatedBytes(precise: false)", scope = "dotnet_managed_process", calculation = "allocated_bytes_delta / elapsed_seconds", cross_platform_comparable = false },
                gc_collection_counts = new { unit = "collections", source = "GC.CollectionCount", scope = "measured_interval", calculation = "separate deltas for generations 0, 1, and 2", cross_platform_comparable = false },
                gc_pause_distribution = new { unit = "ms", source = "EventPipe CLR GC suspend/restart events", scope = "separate_diagnostic_process", calculation = "full pause is GCSuspendEEStart to GCRestartEEStop; fully suspended duration is also reported; GCStart supplies generation, reason, and type", cross_platform_comparable = false }
            },
            platform = "dotnet",
            runtime_configuration_id = "default",
            gc_configuration = new
            {
                server_gc_effective = GCSettings.IsServerGC,
                workstation_gc_effective = !GCSettings.IsServerGC,
                dotnet_gc_server = Environment.GetEnvironmentVariable("DOTNET_GCServer") ?? "unset",
                dotnet_gc_heap_hard_limit = Environment.GetEnvironmentVariable("DOTNET_GCHeapHardLimit") ?? "unset",
                dotnet_gc_conserve_memory = Environment.GetEnvironmentVariable("DOTNET_GCConserveMemory") ?? "unset",
                total_available_memory_bytes = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes,
                logical_processor_count = Environment.ProcessorCount
            },
            session_id = Environment.GetEnvironmentVariable("GC_BENCH_SESSION_ID"),
            repetition = Environment.GetEnvironmentVariable("GC_BENCH_REPETITION"),
            run_order = Environment.GetEnvironmentVariable("GC_BENCH_RUN_ORDER"),
            expected_repetitions = Environment.GetEnvironmentVariable("GC_BENCH_EXPECTED_REPETITIONS"),
            runtime_version = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
            os = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
            architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            scenario, batches, warmup_batches = warmupBatches, items, payload_bytes = payload,
            objects_created_nodes = nodesCreated, retained_nodes_after = Retained.Count, large_buffers_created = largeBuffers,
            payload_bytes_requested = payloadRequested,
            elapsed_ms = total.Elapsed.TotalMilliseconds,
            logical_nodes_per_second = nodesCreated / total.Elapsed.TotalSeconds,
            payload_bytes_per_second = payloadRequested / total.Elapsed.TotalSeconds,
            allocated_bytes_per_second = (after.Allocated - before.Allocated) / total.Elapsed.TotalSeconds,
            allocated_bytes_scope = "dotnet_managed_process",
            allocated_bytes_cross_platform_comparable = false,
            batch_latency_ms = new { p50 = Percentile(batchTimes, .50), p95 = Percentile(batchTimes, .95), p99 = Percentile(batchTimes, .99), samples = batchTimes.Count },
            metrics = new
            {
                allocated_bytes_delta = after.Allocated - before.Allocated,
                heap_used_bytes_before = before.HeapUsed, heap_used_bytes_after_full_gc = afterFullGc.HeapUsed,
                heap_committed_bytes_after_full_gc = afterFullGc.HeapCommitted,
                fragmented_bytes_after_last_gc = after.FragmentedBytes,
                gen0_collections_delta = after.Gen0 - before.Gen0,
                gen1_collections_delta = after.Gen1 - before.Gen1,
                gen2_collections_delta = after.Gen2 - before.Gen2,
                gc_stw_pause_total_ms_delta = (after.PauseTotal - before.PauseTotal).TotalMilliseconds,
                gc_pause_share_percent_process_cumulative = after.PausePercent,
                process_working_set_bytes_after = after.WorkingSet
            },
            checksum = _checksum,
            note = "Warm-up and two explicit full collections are excluded from measured deltas. GetTotalPauseDuration measures managed-thread suspension attributed to GC. Individual pauses are captured only in separate EventPipe diagnostics: full pause is GCSuspendEEStart to GCRestartEEStop, while fully suspended time is reported separately. WorkingSet is a point-in-time process working set, not peak RSS."
        };
        return result;
    }

    public static int Main(string[] args)
    {
        try
        {
            Console.WriteLine(JsonSerializer.Serialize(Run(args), new JsonSerializerOptions { WriteIndented = false }));
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 2;
        }
    }
}
