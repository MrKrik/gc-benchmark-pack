using System.Text.Json;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.EventPipe;
using Microsoft.Diagnostics.Tracing.Parsers;

if (args.Length != 2)
{
    Console.Error.WriteLine("Usage: DotnetGcTrace <input.nettrace> <events.jsonl>");
    return 2;
}

var input = Path.GetFullPath(args[0]);
var output = Path.GetFullPath(args[1]);
if (!File.Exists(input))
{
    Console.Error.WriteLine($"Trace file not found: {input}");
    return 2;
}

var directory = Path.GetDirectoryName(output);
if (directory is not null) Directory.CreateDirectory(directory);

var gcStartCount = 0;
var pauseCount = 0;
var suspendStartCount = 0;
var unmatchedResumeCount = 0;
var measurementActive = false;
var measurementStartCount = 0;
var measurementEndCount = 0;
var gcAssociationFailures = 0;
var duplicateGcStartEvents = 0;
var conflictingGcStartEvents = 0;
var pendingSuspend = new Dictionary<int, (double Timestamp, string Reason, int Count)>();
var pendingPauseStart = new Dictionary<int, (double Timestamp, double SuspendComplete, string Reason, int ExpectedGcCount)>();
var pendingRestartStart = new Dictionary<int, double>();
var gcByCount = new Dictionary<(int ProcessId, int Count), (int Generation, string Reason, string Type, int Count, double Timestamp)>();
using var writer = new StreamWriter(output, false);
using var source = new EventPipeEventSource(input);
var parser = new ClrTraceEventParser(source);
parser.GCStart += data =>
{
    var gc = (
        Generation: data.Depth,
        Reason: data.Reason.ToString(),
        Type: data.Type.ToString(),
        Count: data.Count,
        Timestamp: data.TimeStampRelativeMSec);
    var key = (data.ProcessID, data.Count);
    if (gcByCount.TryGetValue(key, out var existing))
    {
        duplicateGcStartEvents++;
        if (existing.Generation != gc.Generation || existing.Reason != gc.Reason || existing.Type != gc.Type)
            conflictingGcStartEvents++;
    }
    gcByCount[key] = gc;
    if (!measurementActive) return;
    writer.WriteLine(JsonSerializer.Serialize(new
    {
        event_name = "GCStart",
        timestamp_ms = data.TimeStampRelativeMSec,
        process_id = data.ProcessID,
        generation = data.Depth,
        reason = data.Reason.ToString(),
        type = data.Type.ToString(),
        count = data.Count
    }));
    gcStartCount++;
};
parser.GCSuspendEEStart += data =>
{
    if (!measurementActive) return;
    var reason = data.Reason.ToString();
    if (!reason.Contains("GC", StringComparison.OrdinalIgnoreCase)) return;
    pendingSuspend[data.ProcessID] = (data.TimeStampRelativeMSec, reason, data.Count);
    suspendStartCount++;
};
parser.GCSuspendEEStop += data =>
{
    if (!measurementActive) return;
    if (!pendingSuspend.Remove(data.ProcessID, out var suspend)) return;
    pendingPauseStart[data.ProcessID] = (suspend.Timestamp, data.TimeStampRelativeMSec, suspend.Reason, suspend.Count);
};
parser.GCRestartEEStart += data =>
{
    if (!measurementActive) return;
    if (!pendingPauseStart.ContainsKey(data.ProcessID))
    {
        if (pendingSuspend.Remove(data.ProcessID)) unmatchedResumeCount++;
        return;
    }
    pendingRestartStart[data.ProcessID] = data.TimeStampRelativeMSec;
};
parser.GCRestartEEStop += data =>
{
    if (!measurementActive) return;
    if (!pendingPauseStart.Remove(data.ProcessID, out var pause))
    {
        if (pendingSuspend.Remove(data.ProcessID)) unmatchedResumeCount++;
        pendingRestartStart.Remove(data.ProcessID);
        return;
    }
    if (!pendingRestartStart.Remove(data.ProcessID, out var restartStart))
    {
        unmatchedResumeCount++;
        return;
    }

    // A GC pause's count may name the active collection or precede its GCStart
    // by one. Match only starts observed by pause end to avoid choosing a future GC.
    var hasGc = false;
    var gc = default((int Generation, string Reason, string Type, int Count, double Timestamp));
    foreach (var candidateCount in new[] { pause.ExpectedGcCount, pause.ExpectedGcCount + 1 })
    {
        if (gcByCount.TryGetValue((data.ProcessID, candidateCount), out var candidate) &&
            candidate.Timestamp <= data.TimeStampRelativeMSec &&
            (!hasGc || candidate.Timestamp > gc.Timestamp))
        {
            gc = candidate;
            hasGc = true;
        }
    }
    if (!hasGc)
    {
        gcAssociationFailures++;
        Console.Error.WriteLine(
            $"GC pause association failed: process={data.ProcessID}, suspendGcCount={pause.ExpectedGcCount}, " +
            $"no preceding GCStart found for count {pause.ExpectedGcCount} or {pause.ExpectedGcCount + 1}");
        return;
    }
    writer.WriteLine(JsonSerializer.Serialize(new
    {
        event_name = "GCPause",
        start_timestamp_ms = pause.Timestamp,
        end_timestamp_ms = data.TimeStampRelativeMSec,
        duration_ms = Math.Max(0, data.TimeStampRelativeMSec - pause.Timestamp),
        suspension_request_ms = Math.Max(0, pause.SuspendComplete - pause.Timestamp),
        fully_suspended_ms = Math.Max(0, restartStart - pause.SuspendComplete),
        resume_ms = Math.Max(0, data.TimeStampRelativeMSec - restartStart),
        process_id = data.ProcessID,
        suspend_reason = pause.Reason,
        suspend_gc_count = pause.ExpectedGcCount,
        generation = gc.Generation,
        gc_reason = gc.Reason,
        gc_type = gc.Type,
        gc_count = gc.Count,
        gc_start_timestamp_ms = gc.Timestamp
    }));
    pauseCount++;
};
source.Dynamic.All += data =>
{
    if (data.ProviderName != "GC.Bench") return;
    if (data.EventName is "Measurement/Start" or "MeasurementStart")
    {
        measurementStartCount++;
        measurementActive = true;
    }
    else if (data.EventName == "MeasurementEnd")
    {
        measurementEndCount++;
        measurementActive = false;
    }
};
source.Process();
writer.Flush();
var incompleteIntervals = pendingPauseStart.Count + pendingSuspend.Count + pendingRestartStart.Count;
Console.WriteLine(JsonSerializer.Serialize(new
{
    gcStartEvents = gcStartCount,
    suspendEvents = suspendStartCount,
    pauseEvents = pauseCount,
    measurementStartEvents = measurementStartCount,
    measurementEndEvents = measurementEndCount,
    incompleteIntervals,
    unmatchedResumeCount,
    gcEventAssociationFailures = gcAssociationFailures,
    duplicateGcStartEvents,
    conflictingGcStartEvents,
    lostEvents = source.EventsLost
}));
return source.EventsLost == 0 && incompleteIntervals == 0 && unmatchedResumeCount == 0 &&
    gcAssociationFailures == 0 && conflictingGcStartEvents == 0 &&
    measurementStartCount == 1 && measurementEndCount == 1 ? 0 : 1;
