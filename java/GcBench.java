import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryUsage;
import java.lang.management.ThreadMXBean;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.nio.file.Path;
import java.time.Duration;
import com.sun.management.HotSpotDiagnosticMXBean;
import jdk.jfr.Recording;

public final class GcBench {
    static final class Node {
        long id;
        Node left;
        Node right;
        byte[] payload;
        Node(long id, int payloadBytes) {
            this.id = id;
            this.payload = new byte[payloadBytes];
            if (payloadBytes > 0) {
                this.payload[0] = (byte) id;
                this.payload[payloadBytes - 1] = (byte) (id >>> 8);
            }
        }
    }

    private static volatile Node[] sinkNodes;
    private static volatile byte[][] sinkBytes;
    private static final ArrayList<Node> retained = new ArrayList<>();
    private static long checksum;
    private static final com.sun.management.ThreadMXBean allocationBean = getAllocationBean();

    static com.sun.management.ThreadMXBean getAllocationBean() {
        ThreadMXBean base = ManagementFactory.getThreadMXBean();
        if (base instanceof com.sun.management.ThreadMXBean bean && bean.isThreadAllocatedMemorySupported()) {
            try {
                if (!bean.isThreadAllocatedMemoryEnabled()) bean.setThreadAllocatedMemoryEnabled(true);
                return bean;
            } catch (SecurityException ignored) { }
        }
        return null;
    }

    static Node[] makeNodes(int count, int payload, boolean graph) {
        Node[] nodes = new Node[count];
        for (int i = 0; i < count; i++) nodes[i] = new Node(i, payload);
        if (graph && count > 1) {
            for (int i = 0; i < count; i++) {
                nodes[i].left = nodes[(i + 1) % count];
                nodes[i].right = nodes[(i * 17 + 7) % count];
            }
        }
        return nodes;
    }

    static void touch(Node[] nodes) {
        for (Node n : nodes) {
            checksum += n.id + n.payload.length;
            if (n.payload.length > 0) {
                checksum += Byte.toUnsignedInt(n.payload[0]);
                checksum += Byte.toUnsignedInt(n.payload[n.payload.length - 1]);
            }
            if (n.left != null) checksum += n.left.id;
            if (n.right != null) checksum += n.right.id;
        }
    }

    static long allocatedBytes() {
        if (allocationBean == null) return -1;
        return allocationBean.getThreadAllocatedBytes(Thread.currentThread().getId());
    }

    static long heapUsed() {
        MemoryUsage usage = ManagementFactory.getMemoryMXBean().getHeapMemoryUsage();
        return usage.getUsed();
    }

    static long heapCommitted() {
        return ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getCommitted();
    }

    static final class GcSnapshot {
        final Map<String, long[]> byCollector = new LinkedHashMap<>();
        GcSnapshot() {
            for (GarbageCollectorMXBean bean : ManagementFactory.getGarbageCollectorMXBeans()) {
                long c = bean.getCollectionCount();
                long t = bean.getCollectionTime();
                byCollector.put(bean.getName(), new long[]{c, t});
            }
        }
    }

    static Map<String, Long> gcCollectionCounts() {
        Map<String, Long> counts = new LinkedHashMap<>();
        for (GarbageCollectorMXBean bean : ManagementFactory.getGarbageCollectorMXBeans()) {
            counts.put(bean.getName(), bean.getCollectionCount());
        }
        return counts;
    }

    static boolean hasCompletedCollection(Map<String, Long> previousCounts) {
        for (GarbageCollectorMXBean bean : ManagementFactory.getGarbageCollectorMXBeans()) {
            long previous = previousCounts.getOrDefault(bean.getName(), -1L);
            long current = bean.getCollectionCount();
            if (previous >= 0 && current > previous) return true;
        }
        return false;
    }

    static void ensureExplicitGcEnabled() {
        HotSpotDiagnosticMXBean diagnostic = ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class);
        if (diagnostic != null && Boolean.parseBoolean(diagnostic.getVMOption("DisableExplicitGC").getValue())) {
            throw new IllegalStateException("Explicit GC is disabled by the JVM; heap snapshots would be invalid");
        }
        for (String argument : ManagementFactory.getRuntimeMXBean().getInputArguments()) {
            if (argument.equalsIgnoreCase("-XX:+DisableExplicitGC")) {
                throw new IllegalStateException("Explicit GC is disabled by -XX:+DisableExplicitGC; heap snapshots would be invalid");
            }
        }
    }

    static void requestFullGcAndWait() throws InterruptedException {
        ensureExplicitGcEnabled();
        Map<String, Long> previousCounts = gcCollectionCounts();
        System.gc();
        long deadline = System.nanoTime() + Duration.ofSeconds(60).toNanos();
        while (!hasCompletedCollection(previousCounts)) {
            if (System.nanoTime() >= deadline) {
                throw new IllegalStateException("No completed GC was observed after System.gc(); refusing to report a full-GC heap snapshot");
            }
            Thread.sleep(10);
        }
    }

    static Double percentile(List<Double> values, double p) {
        if (values.isEmpty()) return null;
        List<Double> sorted = new ArrayList<>(values);
        sorted.sort(Comparator.naturalOrder());
        double position = (sorted.size() - 1) * p;
        int lower = (int) Math.floor(position);
        int upper = Math.min(lower + 1, sorted.size() - 1);
        double fraction = position - lower;
        return sorted.get(lower) + (sorted.get(upper) - sorted.get(lower)) * fraction;
    }

    static String jsonEscape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
    }

    static String collectorJson(GcSnapshot before, GcSnapshot after) {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, long[]> e : after.byCollector.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            long[] b = before.byCollector.getOrDefault(e.getKey(), new long[]{-1, -1});
            long[] a = e.getValue();
            sb.append('"').append(jsonEscape(e.getKey())).append("\":{\"count_delta\":").append(a[0] < 0 || b[0] < 0 ? "null" : Long.toString(a[0] - b[0]));
            sb.append(",\"elapsed_ms_delta\":").append(a[1] < 0 || b[1] < 0 ? "null" : Long.toString(a[1] - b[1])).append('}');
        }
        return sb.append('}').toString();
    }

    static String nullableNumber(Double value) { return value == null ? "null" : String.format(Locale.ROOT, "%.6f", value); }

    public static void main(String[] args) {
        String scenario = "transient";
        int batches = 1000, warmupBatches = 50, items = 10000, payload = 128;
        String jfrFile = null;
        try {
            for (int i = 0; i < args.length; i++) {
                String key = args[i];
                if (i + 1 >= args.length) throw new IllegalArgumentException("Missing value for " + key);
                String value = args[++i];
                switch (key) {
                    case "--scenario" -> scenario = value;
                    case "--batches" -> batches = Integer.parseInt(value);
                    case "--warmup-batches" -> warmupBatches = Integer.parseInt(value);
                    case "--jfr-file" -> jfrFile = value;
                    case "--items" -> items = Integer.parseInt(value);
                    case "--payload" -> payload = Integer.parseInt(value);
                    default -> throw new IllegalArgumentException("Unknown argument: " + key);
                }
            }
            if (batches < 1 || warmupBatches < 0 || items < 1 || payload < 0) throw new IllegalArgumentException("batches/items must be positive and payload non-negative");
            if (!List.of("transient", "retained", "graph", "large", "mixed").contains(scenario)) throw new IllegalArgumentException("Unknown scenario: " + scenario);
            ensureExplicitGcEnabled();

            retained.clear(); sinkNodes = null; sinkBytes = null;
            int warmItems = items;
            for (int b = 0; b < warmupBatches; b++) {
                if (scenario.equals("large")) {
                    sinkBytes = new byte[warmItems][];
                    for (int i = 0; i < warmItems; i++) sinkBytes[i] = new byte[payload];
                    sinkBytes = null;
                } else {
                    sinkNodes = makeNodes(warmItems, payload, scenario.equals("graph"));
                    touch(sinkNodes);
                    sinkNodes = null;
                }
            }
            retained.clear(); sinkNodes = null; sinkBytes = null;
            // Explicit full-GC request is part of the unmeasured warm-up/reset phase.
            requestFullGcAndWait();
            int retainedPerBatch = Math.max(1, items / 10);
            if (scenario.equals("retained") || scenario.equals("mixed"))
                retained.ensureCapacity(Math.multiplyExact(retainedPerBatch, batches));
            Recording recording = null;
            if (jfrFile != null && !jfrFile.isBlank()) {
                recording = new Recording();
                recording.enable("jdk.GCPhasePause").withThreshold(Duration.ZERO).withoutStackTrace();
                recording.setName("GC benchmark measured interval");
                recording.setToDisk(true);
                recording.setDestination(Path.of(jfrFile));
            }
            long allocBefore = allocatedBytes();
            long heapBefore = heapUsed();
            GcSnapshot gcBefore = new GcSnapshot();
            if (recording != null) recording.start();
            long measurementStartUptimeMs = ManagementFactory.getRuntimeMXBean().getUptime();
            long startNs = System.nanoTime();
            List<Double> batchTimes = new ArrayList<>(batches);
            long nodesCreated = 0, largeBuffers = 0, payloadRequested = 0;

            for (int b = 0; b < batches; b++) {
                long batchStart = System.nanoTime();
                switch (scenario) {
                    case "transient" -> {
                        sinkNodes = makeNodes(items, payload, false);
                        nodesCreated += items; payloadRequested += (long) items * payload;
                        touch(sinkNodes); sinkNodes = null;
                    }
                    case "retained" -> {
                        Node[] batch = makeNodes(items, payload, false);
                        for (int i = 0; i < retainedPerBatch; i++)
                            retained.add(batch[(int) ((long) i * items / retainedPerBatch)]);
                        sinkNodes = batch;
                        nodesCreated += items; payloadRequested += (long) items * payload;
                        touch(sinkNodes); sinkNodes = null;
                    }
                    case "graph" -> {
                        sinkNodes = makeNodes(items, payload, true);
                        nodesCreated += items; payloadRequested += (long) items * payload;
                        touch(sinkNodes); sinkNodes = null;
                    }
                    case "large" -> {
                        sinkBytes = new byte[items][];
                        for (int i = 0; i < items; i++) {
                            sinkBytes[i] = new byte[payload];
                            if (payload > 0) sinkBytes[i][0] = (byte) i;
                        }
                        largeBuffers += items; payloadRequested += (long) items * payload;
                        if (items > 0 && payload > 0) checksum += Byte.toUnsignedInt(sinkBytes[0][0]);
                        sinkBytes = null;
                    }
                    case "mixed" -> {
                        Node[] batch = makeNodes(items, payload, false);
                        int keepCount = Math.max(1, items / 10);
                        for (int i = 0; i < keepCount; i++) retained.add(batch[(int) ((long) i * items / keepCount)]);
                        sinkNodes = batch;
                        touch(sinkNodes);
                        nodesCreated += items; payloadRequested += (long) items * payload;
                        int bigSize = Math.max(1, Math.multiplyExact(payload, 16));
                        sinkBytes = new byte[][]{new byte[bigSize]};
                        largeBuffers++; payloadRequested += bigSize;
                        checksum += Byte.toUnsignedInt(sinkBytes[0][0]);
                        sinkNodes = null; sinkBytes = null;
                    }
                }
                batchTimes.add((System.nanoTime() - batchStart) / 1_000_000.0);
            }
            double elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0;
            // Stop JFR at the measurement boundary, before reading diagnostic
            // MXBeans and memory snapshots. Those reads allocate objects and can
            // otherwise trigger GC events that are outside the measured workload.
            if (recording != null) { recording.stop(); recording.close(); }
            long allocAfter = allocatedBytes();
            GcSnapshot gcAfter = new GcSnapshot();
            long allocDelta = (allocBefore < 0 || allocAfter < 0) ? -1 : allocAfter - allocBefore;
            requestFullGcAndWait();
            long heapAfterFullGc = heapUsed();
            long committedAfterFullGc = heapCommitted();
            // Keep the long-lived graph reachable through the post-measurement full GC.
            if (retained.size() > 0) checksum += retained.get(0).id;

            String inputArgs = ManagementFactory.getRuntimeMXBean().getInputArguments().toString();
            String json = "{" +
                "\"platform\":\"java\",\"session_id\":\"" + jsonEscape(System.getenv().getOrDefault("GC_BENCH_SESSION_ID", "")) + "\",\"repetition\":\"" + jsonEscape(System.getenv().getOrDefault("GC_BENCH_REPETITION", "")) + "\",\"expected_repetitions\":\"" + jsonEscape(System.getenv().getOrDefault("GC_BENCH_EXPECTED_REPETITIONS", "")) + "\",\"run_order\":\"" + jsonEscape(System.getenv().getOrDefault("GC_BENCH_RUN_ORDER", "")) + "\",\"runtime_version\":\"" + jsonEscape(System.getProperty("java.runtime.version")) + "\",\"vm_name\":\"" + jsonEscape(System.getProperty("java.vm.name")) + "\"," +
                "\"os\":\"" + jsonEscape(System.getProperty("os.name") + " " + System.getProperty("os.version")) + "\",\"architecture\":\"" + jsonEscape(System.getProperty("os.arch")) + "\"," +
                "\"scenario\":\"" + scenario + "\",\"batches\":" + batches + ",\"warmup_batches\":" + warmupBatches + ",\"measurement_start_uptime_ms\":" + measurementStartUptimeMs + ",\"items\":" + items + ",\"payload_bytes\":" + payload + "," +
                "\"objects_created_nodes\":" + nodesCreated + ",\"retained_nodes_after\":" + retained.size() + ",\"large_buffers_created\":" + largeBuffers + ",\"payload_bytes_requested\":" + payloadRequested + ",\"elapsed_ms\":" + elapsedMs + "," +
                "\"logical_nodes_per_second\":" + (nodesCreated / (elapsedMs / 1000.0)) + ",\"payload_bytes_per_second\":" + (payloadRequested / (elapsedMs / 1000.0)) + ",\"allocated_bytes_per_second\":" + (allocDelta < 0 ? "null" : Double.toString(allocDelta / (elapsedMs / 1000.0))) + ",\"allocated_bytes_scope\":\"benchmark_thread\"," +
                "\"batch_latency_ms\":{\"p50\":" + nullableNumber(percentile(batchTimes,.50)) + ",\"p95\":" + nullableNumber(percentile(batchTimes,.95)) + ",\"p99\":" + nullableNumber(percentile(batchTimes,.99)) + ",\"samples\":" + batchTimes.size() + "}," +
                "\"metrics\":{\"allocated_bytes_delta_main_thread\":" + (allocDelta < 0 ? "null" : Long.toString(allocDelta)) + ",\"heap_used_bytes_before\":" + heapBefore + ",\"heap_used_bytes_after_full_gc\":" + heapAfterFullGc + ",\"heap_committed_bytes_after_full_gc\":" + committedAfterFullGc + "," +
                "\"gc_stw_pause_total_ms\":null}," +
                "\"gc_collectors_delta\":" + collectorJson(gcBefore, gcAfter) + ",\"jfr_file\":" + (jfrFile == null ? "null" : "\"" + jsonEscape(jfrFile) + "\"") + ",\"jvm_input_arguments\":\"" + jsonEscape(inputArgs) + "\",\"checksum\":" + checksum + "," +
                "\"note\":\"Java allocation counter covers the benchmark thread only, not JVM service threads. MXBean collection counts and elapsed times are reported separately per collector; elapsed time is approximate and is not stop-the-world pause time. Warm-up and verified System.gc() cleanup are excluded from measured deltas. When --jfr-file is supplied, only jdk.GCPhasePause is recorded for the measured interval.\"}";
            System.out.println(json);
        } catch (Exception ex) {
            System.err.println(ex.getMessage());
            System.exit(2);
        }
    }
}
