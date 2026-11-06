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
var pendingSuspend = new Dictionary<int, (double Timestamp, string Reason, int Count)>();
var pendingPauseStart = new Dictionary<int, (double Timestamp, double SuspendComplete, string Reason, int ExpectedGcCount)>();
var pendingRestartStart = new Dictionary<int, double>();
var latestGc = new Dictionary<int, (int Generation, string Reason, string Type, int Count)>();
using var writer = new StreamWriter(output, false);
using var source = new EventPipeEventSource(input);
var parser = new ClrTraceEventParser(source);
parser.GCStart += data =>
{
    latestGc[data.ProcessID] = (data.Depth, data.Reason.ToString(), data.Type.ToString(), data.Count);
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

    if (!latestGc.TryGetValue(data.ProcessID, out var gc) || gc.Count != pause.ExpectedGcCount + 1)
    {
        gcAssociationFailures++;
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
        generation = gc.Generation,
        gc_reason = gc.Reason,
        gc_type = gc.Type,
        gc_count = gc.Count
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
    lostEvents = source.EventsLost
}));
return source.EventsLost == 0 && incompleteIntervals == 0 && unmatchedResumeCount == 0 &&
    gcAssociationFailures == 0 && measurementStartCount == 1 && measurementEndCount == 1 ? 0 : 1;
