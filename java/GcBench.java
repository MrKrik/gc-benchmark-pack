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
import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordingFile;

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
            if (!bean.isThreadAllocatedMemoryEnabled()) bean.setThreadAllocatedMemoryEnabled(true);
            return bean;
        }
        throw new IllegalStateException("The JVM does not support per-thread allocation counters required by this benchmark");
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

    static long totalAllocatedBytes() {
        if (allocationBean == null) return -1;
        return allocationBean.getTotalThreadAllocatedBytes();
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

    static void requestFullGcAndWait() throws Exception {
        ensureExplicitGcEnabled();
        Map<String, Long> previousCounts = gcCollectionCounts();
        Path recordingPath = java.nio.file.Files.createTempFile("gc-bench-explicit-gc-", ".jfr");
        try {
            try (Recording recording = new Recording()) {
                recording.enable("jdk.GarbageCollection").withThreshold(Duration.ZERO).withoutStackTrace();
                recording.enable("jdk.DataLoss").withThreshold(Duration.ZERO).withoutStackTrace();
                recording.setToDisk(true);
                recording.setDestination(recordingPath);
                recording.start();
                System.gc();
                long deadline = System.nanoTime() + Duration.ofSeconds(60).toNanos();
                while (!hasCompletedCollection(previousCounts)) {
                    if (System.nanoTime() >= deadline) {
                        throw new IllegalStateException("No completed GC was observed after System.gc(); refusing to report a full-GC heap snapshot");
                    }
                    Thread.sleep(10);
                }
                recording.stop();
            }
            boolean explicitGcObserved = false;
            for (RecordedEvent event : RecordingFile.readAllEvents(recordingPath)) {
                if (event.getEventType().getName().equals("jdk.DataLoss")) {
                    throw new IllegalStateException("JFR reported lost events while verifying System.gc(); refusing to report a full-GC heap snapshot");
                }
                if (!event.getEventType().getName().equals("jdk.GarbageCollection")) continue;
                if (event.hasField("cause") && event.getString("cause").contains("System.gc")) {
                    explicitGcObserved = true;
                    break;
                }
            }
            if (!explicitGcObserved) {
                throw new IllegalStateException("A GC completed after System.gc(), but JFR did not confirm an explicit-GC cause; refusing to report a full-GC heap snapshot");
            }
        } finally {
            java.nio.file.Files.deleteIfExists(recordingPath);
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
            int retainedPerBatch = Math.max(1, items / 10);
            if (scenario.equals("retained") || scenario.equals("mixed"))
                retained.ensureCapacity(Math.multiplyExact(retainedPerBatch, warmupBatches));
            int warmItems = items;
            for (int b = 0; b < warmupBatches; b++) {
                switch (scenario) {
                    case "retained" -> {
                        Node[] batch = makeNodes(warmItems, payload, false);
                        for (int i = 0; i < retainedPerBatch; i++)
                            retained.add(batch[(int) ((long) i * warmItems / retainedPerBatch)]);
                        sinkNodes = batch;
                        touch(sinkNodes);
                        sinkNodes = null;
                    }
                    case "mixed" -> {
                        Node[] batch = makeNodes(warmItems, payload, false);
                        for (int i = 0; i < retainedPerBatch; i++)
                            retained.add(batch[(int) ((long) i * warmItems / retainedPerBatch)]);
                        sinkNodes = batch;
                        touch(sinkNodes);
                        sinkBytes = new byte[][]{new byte[Math.max(1, Math.multiplyExact(payload, 16))]};
                        checksum += Byte.toUnsignedInt(sinkBytes[0][0]);
                        sinkNodes = null;
                        sinkBytes = null;
                    }
                    case "large" -> {
                        sinkBytes = new byte[warmItems][];
                        for (int i = 0; i < warmItems; i++) {
                            sinkBytes[i] = new byte[payload];
                            if (payload > 0) sinkBytes[i][0] = (byte) i;
                        }
                        if (warmItems > 0 && payload > 0) checksum += Byte.toUnsignedInt(sinkBytes[0][0]);
                        sinkBytes = null;
                    }
                    default -> {
                        sinkNodes = makeNodes(warmItems, payload, scenario.equals("graph"));
                        touch(sinkNodes);
                        sinkNodes = null;
                    }
                }
            }
            retained.clear(); sinkNodes = null; sinkBytes = null;
            // Explicit full-GC request is part of the unmeasured warm-up/reset phase.
            requestFullGcAndWait();
            if (scenario.equals("retained") || scenario.equals("mixed"))
                retained.ensureCapacity(Math.multiplyExact(retainedPerBatch, batches));
            Recording recording = null;
            if (jfrFile != null && !jfrFile.isBlank()) {
                recording = new Recording();
                recording.enable("jdk.GCPhasePause").withThreshold(Duration.ZERO).withoutStackTrace();
                recording.enable("jdk.GarbageCollection").withThreshold(Duration.ZERO).withoutStackTrace();
                recording.enable("jdk.DataLoss").withThreshold(Duration.ZERO).withoutStackTrace();
                recording.setName("GC benchmark measured interval");
                recording.setToDisk(true);
                recording.setDestination(Path.of(jfrFile));
            }
            long allocBefore = totalAllocatedBytes();
            long mainThreadAllocBefore = allocatedBytes();
            long heapBefore = heapUsed();
            GcSnapshot gcBefore = new GcSnapshot();
            if (recording != null) recording.start();
            List<Double> batchTimes = new ArrayList<>(batches);
            long nodesCreated = 0, largeBuffers = 0, payloadRequested = 0;
            long measurementStartUptimeMs = ManagementFactory.getRuntimeMXBean().getUptime();
            long startNs = System.nanoTime();

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
            long allocAfter = totalAllocatedBytes();
            long mainThreadAllocAfter = allocatedBytes();
            GcSnapshot gcAfter = new GcSnapshot();
            long allocDelta = (allocBefore < 0 || allocAfter < 0) ? -1 : allocAfter - allocBefore;
            long mainThreadAllocDelta = (mainThreadAllocBefore < 0 || mainThreadAllocAfter < 0) ? -1 : mainThreadAllocAfter - mainThreadAllocBefore;
            requestFullGcAndWait();
            long heapAfterFullGc = heapUsed();
            long committedAfterFullGc = heapCommitted();
            // Keep the long-lived graph reachable through the post-measurement full GC.
            if (retained.size() > 0) checksum += retained.get(0).id;

            String inputArgs = ManagementFactory.getRuntimeMXBean().getInputArguments().toString();
            String javaOptions = System.getenv().getOrDefault("JAVA_OPTS", "");
            String configurationId = System.getenv().getOrDefault("GC_BENCH_JAVA_CONFIGURATION", "");
            if (configurationId.isBlank()) configurationId = inputArgs.equals("[]") ? "java-default" : "java-custom";
            HotSpotDiagnosticMXBean hotspot = ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class);
            String g1RegionSize = hotspot.getVMOption("G1HeapRegionSize").getValue();
            String gcConfiguration = "{\"java_opts\":\"" + jsonEscape(javaOptions) +
                "\",\"input_arguments\":\"" + jsonEscape(inputArgs) + "\",\"collectors\":" +
                ManagementFactory.getGarbageCollectorMXBeans().stream()
                    .map(gc -> "\"" + jsonEscape(gc.getName()) + "\"")
                    .collect(java.util.stream.Collectors.joining(",", "[", "]")) +
                ",\"heap_initial_bytes\":" + ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getInit() +
                ",\"heap_max_bytes\":" + Runtime.getRuntime().maxMemory() +
                ",\"g1_region_size_bytes\":" + g1RegionSize + "}";
            String json = "{" +
                "\"schema_version\":2,\"metric_definitions\":{\"allocated_bytes_delta_all_threads\":{\"unit\":\"bytes\",\"source\":\"ThreadMXBean.getTotalThreadAllocatedBytes\",\"scope\":\"all_java_threads\",\"calculation\":\"total counter after - total counter before\",\"cross_platform_comparable\":false},\"allocated_bytes_delta_main_thread\":{\"unit\":\"bytes\",\"source\":\"ThreadMXBean.getThreadAllocatedBytes(currentThreadId)\",\"scope\":\"benchmark_thread\",\"calculation\":\"thread counter after - thread counter before\",\"cross_platform_comparable\":false},\"allocated_bytes_per_second\":{\"unit\":\"bytes/s\",\"source\":\"ThreadMXBean.getTotalThreadAllocatedBytes\",\"scope\":\"all_java_threads\",\"calculation\":\"allocated_bytes_delta_all_threads / elapsed_seconds\",\"cross_platform_comparable\":false},\"gc_collector_counts\":{\"unit\":\"collections\",\"source\":\"GarbageCollectorMXBean.getCollectionCount\",\"scope\":\"each_collector_separately\",\"calculation\":\"per-collector counter after - counter before; never summed\",\"cross_platform_comparable\":false},\"gc_pause_distribution\":{\"unit\":\"ms\",\"source\":\"JFR jdk.GCPhasePause\",\"scope\":\"separate_diagnostic_recording\",\"calculation\":\"individual JFR pause event durations\",\"cross_platform_comparable\":false}}," +
                "\"platform\":\"java\",\"runtime_configuration_id\":\"" + jsonEscape(configurationId) + "\",\"gc_configuration\":" + gcConfiguration + ",\"session_id\":\"" + jsonEscape(System.getenv().getOrDefault("GC_BENCH_SESSION_ID", "")) + "\",\"repetition\":\"" + jsonEscape(System.getenv().getOrDefault("GC_BENCH_REPETITION", "")) + "\",\"expected_repetitions\":\"" + jsonEscape(System.getenv().getOrDefault("GC_BENCH_EXPECTED_REPETITIONS", "")) + "\",\"run_order\":\"" + jsonEscape(System.getenv().getOrDefault("GC_BENCH_RUN_ORDER", "")) + "\",\"runtime_version\":\"" + jsonEscape(System.getProperty("java.runtime.version")) + "\",\"vm_name\":\"" + jsonEscape(System.getProperty("java.vm.name")) + "\"," +
                "\"os\":\"" + jsonEscape(System.getProperty("os.name") + " " + System.getProperty("os.version")) + "\",\"architecture\":\"" + jsonEscape(System.getProperty("os.arch")) + "\"," +
                "\"scenario\":\"" + scenario + "\",\"batches\":" + batches + ",\"warmup_batches\":" + warmupBatches + ",\"measurement_start_uptime_ms\":" + measurementStartUptimeMs + ",\"items\":" + items + ",\"payload_bytes\":" + payload + "," +
                "\"objects_created_nodes\":" + nodesCreated + ",\"retained_nodes_after\":" + retained.size() + ",\"large_buffers_created\":" + largeBuffers + ",\"payload_bytes_requested\":" + payloadRequested + ",\"elapsed_ms\":" + elapsedMs + "," +
                "\"logical_nodes_per_second\":" + (nodesCreated / (elapsedMs / 1000.0)) + ",\"payload_bytes_per_second\":" + (payloadRequested / (elapsedMs / 1000.0)) + ",\"allocated_bytes_per_second\":" + (allocDelta < 0 ? "null" : Double.toString(allocDelta / (elapsedMs / 1000.0))) + ",\"allocated_bytes_scope\":\"all_java_threads_runtime_counter\",\"allocated_bytes_cross_platform_comparable\":false," +
                "\"batch_latency_ms\":{\"p50\":" + nullableNumber(percentile(batchTimes,.50)) + ",\"p95\":" + nullableNumber(percentile(batchTimes,.95)) + ",\"p99\":" + nullableNumber(percentile(batchTimes,.99)) + ",\"samples\":" + batchTimes.size() + "}," +
                "\"metrics\":{\"allocated_bytes_delta_all_threads\":" + (allocDelta < 0 ? "null" : Long.toString(allocDelta)) + ",\"allocated_bytes_delta_main_thread\":" + (mainThreadAllocDelta < 0 ? "null" : Long.toString(mainThreadAllocDelta)) + ",\"heap_used_bytes_before\":" + heapBefore + ",\"heap_used_bytes_after_full_gc\":" + heapAfterFullGc + ",\"heap_committed_bytes_after_full_gc\":" + committedAfterFullGc + "," +
                "\"gc_stw_pause_total_ms\":null}," +
                "\"gc_collectors_delta\":" + collectorJson(gcBefore, gcAfter) + ",\"jfr_file\":" + (jfrFile == null ? "null" : "\"" + jsonEscape(jfrFile) + "\"") + ",\"jvm_input_arguments\":\"" + jsonEscape(inputArgs) + "\",\"checksum\":" + checksum + "," +
                "\"note\":\"Java allocation metrics preserve both the all-thread runtime counter and benchmark-thread counter; neither is treated as cross-platform comparable because runtime counter scopes differ. MXBean collection counts and elapsed times are reported separately per collector; elapsed time is approximate and is not stop-the-world pause time. Full-GC snapshots require a JFR jdk.GarbageCollection event whose cause confirms System.gc(), with no jdk.DataLoss event. When --jfr-file is supplied, only jdk.GCPhasePause, jdk.GarbageCollection, and jdk.DataLoss are recorded for the measured interval.\"}";
            System.out.println(json);
        } catch (Exception ex) {
            System.err.println(ex.getMessage());
            System.exit(2);
        }
    }
}
