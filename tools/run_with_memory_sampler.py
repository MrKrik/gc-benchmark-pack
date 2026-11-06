import argparse
import ctypes
import json
import platform
import shlex
import subprocess
import sys
import threading
import time


class ProcessMemoryCountersEx(ctypes.Structure):
    _fields_ = [
        ("cb", ctypes.c_ulong),
        ("PageFaultCount", ctypes.c_ulong),
        ("PeakWorkingSetSize", ctypes.c_size_t),
        ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t),
        ("PeakPagefileUsage", ctypes.c_size_t),
        ("PrivateUsage", ctypes.c_size_t),
    ]


def windows_memory_reader(pid):
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    kernel32.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    psapi.GetProcessMemoryInfo.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ProcessMemoryCountersEx),
        ctypes.c_ulong,
    ]
    psapi.GetProcessMemoryInfo.restype = ctypes.c_int
    handle = kernel32.OpenProcess(0x0400 | 0x0010, 0, pid)
    if not handle:
        raise OSError(ctypes.get_last_error(), "OpenProcess failed")

    def read():
        counters = ProcessMemoryCountersEx()
        counters.cb = ctypes.sizeof(counters)
        if not psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
            raise OSError(ctypes.get_last_error(), "GetProcessMemoryInfo failed")
        return counters.WorkingSetSize, counters.PeakWorkingSetSize

    return read, lambda: kernel32.CloseHandle(handle), "GetProcessMemoryInfo(PeakWorkingSetSize)"


def linux_memory_reader(pid):
    path = "/proc/{}/status".format(pid)

    def read():
        values = {}
        with open(path, encoding="ascii") as status:
            for line in status:
                if line.startswith(("VmRSS:", "VmHWM:")):
                    name, value, _unit = line.split()
                    values[name] = int(value) * 1024
        if "VmRSS:" not in values or "VmHWM:" not in values:
            raise RuntimeError("Linux process status lacks VmRSS or VmHWM")
        return values["VmRSS:"], values["VmHWM:"]

    return read, lambda: None, "/proc/<pid>/status VmHWM"


def mac_memory_reader(pid):
    def read():
        result = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(pid)],
            check=True,
            capture_output=True,
            text=True,
        )
        value = result.stdout.strip()
        if not value:
            raise ProcessLookupError("process exited before memory sample")
        rss = int(value) * 1024
        return rss, rss

    return read, lambda: None, "sampled ps RSS (peak is sampled)"


def make_memory_reader(pid):
    system = platform.system()
    if system == "Windows":
        return windows_memory_reader(pid)
    if system == "Linux":
        return linux_memory_reader(pid)
    if system == "Darwin":
        return mac_memory_reader(pid)
    raise RuntimeError("Memory sampling is unsupported on {}".format(system))


def split_java_options(value):
    if platform.system() != "Windows" or not value:
        return shlex.split(value)
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    shell32.CommandLineToArgvW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
    shell32.CommandLineToArgvW.restype = ctypes.POINTER(ctypes.c_wchar_p)
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    count = ctypes.c_int()
    parsed = shell32.CommandLineToArgvW(value, ctypes.byref(count))
    if not parsed:
        raise OSError(ctypes.get_last_error(), "CommandLineToArgvW failed for JAVA_OPTS")
    try:
        return [parsed[index] for index in range(count.value)]
    finally:
        kernel32.LocalFree(parsed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--interval-ms", type=int, default=50)
    parser.add_argument("--java-options", default="")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("benchmark command is required after --")
    if args.interval_ms < 10:
        parser.error("--interval-ms must be at least 10")
    if args.java_options:
        command = command[:1] + split_java_options(args.java_options) + command[1:]

    process = subprocess.Popen(command, stdout=subprocess.PIPE)
    try:
        read_memory, close_reader, source = make_memory_reader(process.pid)
    except Exception:
        process.terminate()
        process.wait()
        raise

    output_parts = []
    reader_thread = threading.Thread(target=lambda: output_parts.append(process.stdout.read()))
    reader_thread.start()
    samples = []
    try:
        first, observed_peak = read_memory()
        samples.append(first)
    except Exception as error:
        process.terminate()
        process.wait()
        close_reader()
        raise RuntimeError("Initial process memory sample failed: {}".format(error))
    last = first
    peak = observed_peak
    sample_error = None
    interval = args.interval_ms / 1000.0
    while process.poll() is None:
        try:
            current, observed_peak = read_memory()
            if first is None:
                first = current
            last = current
            peak = max(peak, observed_peak)
            samples.append(current)
        except ProcessLookupError:
            break
        except Exception as error:
            sample_error = error
            break
        time.sleep(interval)

    return_code = process.wait()
    reader_thread.join()
    try:
        current, observed_peak = read_memory()
        if first is None:
            first = current
        if last is None:
            last = current
        peak = max(peak, observed_peak)
    except ProcessLookupError:
        pass
    except Exception as error:
        sample_error = sample_error or error
    finally:
        close_reader()

    raw_output = b"".join(output_parts)
    sys.stdout.buffer.write(raw_output)
    sys.stdout.buffer.flush()
    if return_code:
        return return_code
    if sample_error:
        raise RuntimeError("Memory sampling failed: {}".format(sample_error))

    result_lines = [line for line in raw_output.decode("utf-8").splitlines() if line.strip()]
    if len(result_lines) != 1:
        raise RuntimeError("Expected exactly one JSON result line from benchmark process")
    result = json.loads(result_lines[0])
    if first is None or last is None or peak == 0:
        raise RuntimeError("No valid process memory samples were collected")

    result["memory_metrics"] = {
        "peak_working_set_bytes": peak,
        "average_sampled_working_set_bytes": sum(samples) / len(samples) if samples else last,
        "initial_working_set_bytes": first,
        "final_working_set_bytes": last,
        "sample_count": len(samples),
        "sampling_interval_ms": args.interval_ms,
        "source": source,
        "scope": "benchmark_process_resident_memory",
        "cross_platform_comparable": platform.system() != "Darwin",
    }
    comparable_peak = platform.system() != "Darwin"
    result["memory_metric_definitions"] = {
        "peak_working_set_bytes": {
            "unit": "bytes",
            "source": source,
            "scope": "benchmark_process_resident_memory",
            "calculation": "process peak Working Set reported by OS; sampled maximum on macOS",
            "cross_platform_comparable": comparable_peak,
        },
        "average_sampled_working_set_bytes": {
            "unit": "bytes",
            "source": "external process Working Set samples",
            "scope": "benchmark_process_resident_memory",
            "calculation": "arithmetic mean of samples at the configured interval",
            "cross_platform_comparable": True,
        },
        "initial_working_set_bytes": {
            "unit": "bytes",
            "source": "external process Working Set sample",
            "scope": "benchmark_process_resident_memory",
            "calculation": "first sample after process start",
            "cross_platform_comparable": True,
        },
        "final_working_set_bytes": {
            "unit": "bytes",
            "source": "external process Working Set sample",
            "scope": "benchmark_process_resident_memory",
            "calculation": "last sample before process exit",
            "cross_platform_comparable": True,
        },
    }
    with open(args.output, "a", encoding="utf-8", newline="\n") as output_file:
        output_file.write(json.dumps(result, separators=(",", ":"), ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("ERROR: {}".format(error), file=sys.stderr)
        sys.exit(2)
