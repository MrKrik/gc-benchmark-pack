@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem One-click full GC experiment for Windows CMD.
rem Usage: RUN_ALL_GC_EXPERIMENTS.bat [runs] [items] [batches] [payload]
rem Defaults: 10 10000 1000 128
rem Optional: set SKIP_LARGE_OBJECT_SERIES=1 to omit the additional 1 MiB test.

set "ROOT=%~dp0"
set "RUNS=%~1"
set "ITEMS=%~2"
set "BATCHES=%~3"
set "PAYLOAD=%~4"
if not defined RUNS set "RUNS=10"
if not defined ITEMS set "ITEMS=10000"
if not defined BATCHES set "BATCHES=1000"
if not defined PAYLOAD set "PAYLOAD=128"
if not defined WARMUP_BATCHES set "WARMUP_BATCHES=50"

if not exist "%ROOT%tools\run_all_scenarios.bat" (
  echo ERROR: Run this file from the extracted project folder.
  echo Missing: %ROOT%tools\run_all_scenarios.bat
  goto :preflight_failed
)

rem Required toolchain checks.
where python >nul 2>nul || (echo ERROR: Python 3.10+ not found in PATH.& goto :preflight_failed)
python -c "import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)"
if errorlevel 1 (
  echo ERROR: Python 3.10 or newer is required.
  goto :preflight_failed
)
where go >nul 2>nul || (echo ERROR: Go not found in PATH.& goto :preflight_failed)
where dotnet >nul 2>nul || (echo ERROR: .NET SDK not found in PATH.& goto :preflight_failed)
where dotnet-trace >nul 2>nul
if errorlevel 1 if not exist "%USERPROFILE%\.dotnet\tools\dotnet-trace.exe" (
  echo ERROR: dotnet-trace is required for separate .NET GC diagnostics.
  echo Install it with: dotnet tool install --global dotnet-trace
  goto :preflight_failed
)
dotnet --list-sdks | findstr /R /C:"^10\." >nul
if errorlevel 1 (
  echo ERROR: .NET 10 SDK is required. Installed SDKs:
  dotnet --list-sdks
  goto :preflight_failed
)
where javac >nul 2>nul || (echo ERROR: JDK javac not found in PATH.& goto :preflight_failed)
for /f "tokens=2" %%V in ('javac -version 2^>^&1') do set "JDK_VERSION=%%V"
for /f "tokens=1 delims=." %%V in ("%JDK_VERSION%") do set "JDK_MAJOR=%%V"
if not defined JDK_MAJOR (
  echo ERROR: Could not determine the JDK version.
  goto :preflight_failed
)
if %JDK_MAJOR% LSS 21 (
  echo ERROR: JDK 21 or newer is required; found javac %JDK_VERSION%.
  goto :preflight_failed
)
where java >nul 2>nul || (echo ERROR: Java runtime not found in PATH.& goto :preflight_failed)
where jfr >nul 2>nul
if errorlevel 1 if defined JAVA_HOME if exist "%JAVA_HOME%\bin\jfr.exe" set "PATH=%JAVA_HOME%\bin;%PATH%"
where jfr >nul 2>nul
if errorlevel 1 for /f "tokens=3,*" %%A in ('java -XshowSettings:properties -version 2^>^&1 ^| findstr /C:"java.home ="') do set "JDK_HOME=%%A %%B"
if defined JDK_HOME if exist "%JDK_HOME%\bin\jfr.exe" set "PATH=%JDK_HOME%\bin;%PATH%"
where jfr >nul 2>nul
if errorlevel 1 (
  echo ERROR: JDK jfr.exe was not found. Add the JDK bin directory to PATH or set JAVA_HOME.
  goto :preflight_failed
)

rem Create a new result folder for every execution; never overwrite previous experiments.
set "RUN_ID="
for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss" 2^>nul') do set "RUN_ID=%%I"
if not defined RUN_ID set "RUN_ID=manual_%RANDOM%_%RANDOM%"
set "RUN_ID=%RUN_ID%_%RANDOM%"
set "RESULTS_SUBDIR=run_%RUN_ID%"
set "BASE_RESULTS_SUBDIR=%RESULTS_SUBDIR%"
set "GC_BENCH_SESSION_ID=%BASE_RESULTS_SUBDIR%"
set "GC_BENCH_EXPECTED_REPETITIONS=%RUNS%"
set "GC_BENCH_JAVA_CONFIGURATION=java-baseline-default"
if defined JAVA_OPTS set "GC_BENCH_JAVA_CONFIGURATION=java-baseline-custom-options"
if defined JAVA_TOOL_OPTIONS set "GC_BENCH_JAVA_CONFIGURATION=java-baseline-custom-options"
if defined _JAVA_OPTIONS set "GC_BENCH_JAVA_CONFIGURATION=java-baseline-custom-options"
set "RUN_DIR=%ROOT%results\%BASE_RESULTS_SUBDIR%"
if not exist "%RUN_DIR%" mkdir "%RUN_DIR%"
if errorlevel 1 (
  echo ERROR: Cannot create results folder: %RUN_DIR%
  goto :preflight_failed
)

(
  echo GC benchmark experiment
  echo Run ID: %RUN_ID%
  echo Base parameters: runs=%RUNS%, items=%ITEMS%, batches=%BATCHES%, payload_bytes=%PAYLOAD%, warmup_batches=%WARMUP_BATCHES%
  echo Large-object series: items=64, batches=10, payload_bytes=1048576
  echo Large-object Java JFR diagnostic flags only; baseline uses JVM defaults: -Xms512m -Xmx512m -XX:+UseG1GC -XX:G1HeapRegionSize=1m
  echo Large-object Java baseline clears JAVA_OPTS, JAVA_TOOL_OPTIONS and _JAVA_OPTIONS.
  echo Large-object Java G1/JFR diagnostic clears JAVA_TOOL_OPTIONS and _JAVA_OPTIONS; fixed JAVA_OPTS are applied explicitly.
  echo Java minimum: JDK 21
  echo GOGC=%GOGC%
  echo GOMEMLIMIT=%GOMEMLIMIT%
  echo GOMAXPROCS=%GOMAXPROCS%
  echo DOTNET_GCServer=%DOTNET_GCServer%
  echo DOTNET_GCHeapHardLimit=%DOTNET_GCHeapHardLimit%
  echo DOTNET_GCConserveMemory=%DOTNET_GCConserveMemory%
  echo JAVA_OPTS=%JAVA_OPTS%
  echo JAVA_TOOL_OPTIONS=%JAVA_TOOL_OPTIONS%
  echo _JAVA_OPTIONS=%_JAVA_OPTIONS%
  echo Java baseline configuration ID: %GC_BENCH_JAVA_CONFIGURATION%
  echo.
  echo --- OS ---
  powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption; ver"
  echo.
  echo --- Go ---
  go version
  echo.
  echo --- .NET SDKs ---
  dotnet --list-sdks
  echo.
  echo --- Java ---
  javac -version
  java -version
  java %JAVA_OPTS% -XX:+PrintFlagsFinal -version 2^>^&1 | findstr /I /C:"InitialHeapSize" /C:"MaxHeapSize" /C:"UseG1GC" /C:"G1HeapRegionSize" /C:"UseParallelGC" /C:"UseZGC" /C:"UseSerialGC"
  echo.
  echo --- Python ---
  python --version
  echo.
  echo --- CPU and memory ---
  powershell -NoProfile -Command "Get-CimInstance Win32_Processor | Select-Object -First 1 Name,NumberOfCores,NumberOfLogicalProcessors; 'RAM bytes: ' + (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory"
) > "%RUN_DIR%\experiment-info.txt" 2>&1

 echo.
 echo ============================================================
 echo Full GC experiment
 echo Result folder: results\%BASE_RESULTS_SUBDIR%
 echo Base matrix: 3 platforms x 5 scenarios x %RUNS% repetitions
 echo Java JFR diagnostics: 5 scenarios x %RUNS% recordings
 echo .NET EventPipe diagnostics: 5 scenarios x %RUNS% separate runs
 if /I not "%SKIP_LARGE_OBJECT_SERIES%"=="1" echo Extra large-object matrix: 3 platforms x %RUNS% repetitions
 echo ============================================================
 echo.
choice /C YN /M "Start the experiment"
if errorlevel 2 (
  echo Cancelled. No benchmark was started.
  pause
  exit /b 3
)

rem Stage 1: standard matrix, Go + .NET 10 + Java, all five scenarios.
echo.
echo [1/6] Running standard benchmark matrix...
set "RESULTS_SUBDIR=%BASE_RESULTS_SUBDIR%"
call "%ROOT%tools\run_all_scenarios.bat" %RUNS% %ITEMS% %BATCHES% %PAYLOAD%
if errorlevel 1 goto :failed

rem Stage 2: collect .NET GC pause events in separate diagnostic runs.
echo.
echo [2/6] Recording .NET EventPipe GC diagnostics for all five scenarios...
call "%ROOT%tools\run_dotnet_gc_diagnostic.bat" "%BASE_RESULTS_SUBDIR%" %RUNS% %ITEMS% %BATCHES% %PAYLOAD% %WARMUP_BATCHES%
if errorlevel 1 goto :failed

rem Stage 3: Java JFR recordings with the same baseline workload parameters.
echo.
echo [3/6] Recording Java JFR pauses for all five baseline scenarios...
set "GC_BENCH_JFR_CONFIGURATION=java-jfr-diagnostic-default"
if defined JAVA_OPTS set "GC_BENCH_JFR_CONFIGURATION=java-jfr-diagnostic-custom-options"
if defined JAVA_TOOL_OPTIONS set "GC_BENCH_JFR_CONFIGURATION=java-jfr-diagnostic-custom-options"
if defined _JAVA_OPTIONS set "GC_BENCH_JFR_CONFIGURATION=java-jfr-diagnostic-custom-options"
for %%S in (transient retained graph large mixed) do (
  echo.
  echo --- Java JFR: %%S ---
  call "%ROOT%tools\run_java_jfr.bat" %%S %RUNS% %ITEMS% %BATCHES% %PAYLOAD%
  if errorlevel 1 goto :failed
)

rem Stage 4: export Java STW pause events to CSV.
echo.
echo [4/6] Processing baseline Java JFR recordings...
call "%ROOT%tools\process_java_jfr.bat"
if errorlevel 1 goto :failed
set "GC_BENCH_JFR_CONFIGURATION="

echo.
echo === Adding Java JFR analysis to scenario reports ===
python "%ROOT%tools\visualize_results.py" "%ROOT%results\%BASE_RESULTS_SUBDIR%\comparison-all-scenarios.csv" -o "%ROOT%results\%BASE_RESULTS_SUBDIR%\report-all" --split-by-scenario --jfr-analysis-dir "%ROOT%results\%BASE_RESULTS_SUBDIR%\jfr-analysis" --dotnet-eventpipe-analysis-dir "%ROOT%results\%BASE_RESULTS_SUBDIR%\dotnet-eventpipe"
if errorlevel 1 goto :failed

rem Stage 5: targeted 1 MiB object series, kept in a separate subfolder.
if /I "%SKIP_LARGE_OBJECT_SERIES%"=="1" goto :finish

echo.
echo [5/6] Running targeted 1 MiB large-object series...
set "RESULTS_SUBDIR=%BASE_RESULTS_SUBDIR%\large-object-series"
set "GC_BENCH_SESSION_ID=%BASE_RESULTS_SUBDIR%\large-object-series"
call "%ROOT%tools\run_repeat.bat" go large %RUNS% 64 10 1048576
if errorlevel 1 goto :failed
call "%ROOT%tools\run_repeat.bat" dotnet large %RUNS% 64 10 1048576
if errorlevel 1 goto :failed
call "%ROOT%tools\run_dotnet_gc_diagnostic.bat" "%BASE_RESULTS_SUBDIR%\large-object-series" %RUNS% 64 10 1048576 %WARMUP_BATCHES% large
if errorlevel 1 goto :failed

rem Baseline Java run uses default JVM settings and no JFR, like the other platforms.
set "SAVED_JAVA_OPTS=%JAVA_OPTS%"
set "SAVED_JAVA_TOOL_OPTIONS=%JAVA_TOOL_OPTIONS%"
set "SAVED_UNDERSCORE_JAVA_OPTIONS=%_JAVA_OPTIONS%"
set "SAVED_JAVA_CONFIGURATION=%GC_BENCH_JAVA_CONFIGURATION%"
set "HAD_JAVA_OPTS="
set "HAD_JAVA_TOOL_OPTIONS="
set "HAD_UNDERSCORE_JAVA_OPTIONS="
if defined JAVA_OPTS set "HAD_JAVA_OPTS=1"
if defined JAVA_TOOL_OPTIONS set "HAD_JAVA_TOOL_OPTIONS=1"
if defined _JAVA_OPTIONS set "HAD_UNDERSCORE_JAVA_OPTIONS=1"
set "JAVA_OPTS="
set "JAVA_TOOL_OPTIONS="
set "_JAVA_OPTIONS="
set "GC_BENCH_JAVA_CONFIGURATION=java-large-baseline-default"
call "%ROOT%tools\run_repeat.bat" java large %RUNS% 64 10 1048576
set "JAVA_LARGE_BASELINE_RC=%ERRORLEVEL%"
if defined HAD_JAVA_OPTS (set "JAVA_OPTS=%SAVED_JAVA_OPTS%") else set "JAVA_OPTS="
if defined HAD_JAVA_TOOL_OPTIONS (set "JAVA_TOOL_OPTIONS=%SAVED_JAVA_TOOL_OPTIONS%") else set "JAVA_TOOL_OPTIONS="
if defined HAD_UNDERSCORE_JAVA_OPTIONS (set "_JAVA_OPTIONS=%SAVED_UNDERSCORE_JAVA_OPTIONS%") else set "_JAVA_OPTIONS="
set "GC_BENCH_JAVA_CONFIGURATION=%SAVED_JAVA_CONFIGURATION%"
set "SAVED_JAVA_OPTS="
set "SAVED_JAVA_TOOL_OPTIONS="
set "SAVED_UNDERSCORE_JAVA_OPTIONS="
set "SAVED_JAVA_CONFIGURATION="
set "HAD_JAVA_OPTS="
set "HAD_JAVA_TOOL_OPTIONS="
set "HAD_UNDERSCORE_JAVA_OPTIONS="
if not "%JAVA_LARGE_BASELINE_RC%"=="0" goto :failed
set "JAVA_LARGE_BASELINE_RC="

rem A separately labeled JFR diagnostic uses fixed G1 region settings; do not
rem include it in the uninstrumented cross-platform performance table.
set "SAVED_JAVA_OPTS=%JAVA_OPTS%"
set "SAVED_JAVA_TOOL_OPTIONS=%JAVA_TOOL_OPTIONS%"
set "SAVED_UNDERSCORE_JAVA_OPTIONS=%_JAVA_OPTIONS%"
set "SAVED_JFR_CONFIGURATION=%GC_BENCH_JFR_CONFIGURATION%"
set "HAD_JAVA_OPTS="
set "HAD_JAVA_TOOL_OPTIONS="
set "HAD_UNDERSCORE_JAVA_OPTIONS="
set "HAD_JFR_CONFIGURATION="
if defined JAVA_OPTS set "HAD_JAVA_OPTS=1"
if defined JAVA_TOOL_OPTIONS set "HAD_JAVA_TOOL_OPTIONS=1"
if defined _JAVA_OPTIONS set "HAD_UNDERSCORE_JAVA_OPTIONS=1"
if defined GC_BENCH_JFR_CONFIGURATION set "HAD_JFR_CONFIGURATION=1"
set "JAVA_OPTS=-Xms512m -Xmx512m -XX:+UseG1GC -XX:G1HeapRegionSize=1m"
set "JAVA_TOOL_OPTIONS="
set "_JAVA_OPTIONS="
set "GC_BENCH_JFR_CONFIGURATION=java-g1-xms512m-xmx512m-region1m-jfr"
call "%ROOT%tools\run_java_jfr.bat" large %RUNS% 64 10 1048576
set "JAVA_LARGE_JFR_RC=%ERRORLEVEL%"
if defined HAD_JAVA_OPTS (set "JAVA_OPTS=%SAVED_JAVA_OPTS%") else set "JAVA_OPTS="
if defined HAD_JAVA_TOOL_OPTIONS (set "JAVA_TOOL_OPTIONS=%SAVED_JAVA_TOOL_OPTIONS%") else set "JAVA_TOOL_OPTIONS="
if defined HAD_UNDERSCORE_JAVA_OPTIONS (set "_JAVA_OPTIONS=%SAVED_UNDERSCORE_JAVA_OPTIONS%") else set "_JAVA_OPTIONS="
if defined HAD_JFR_CONFIGURATION (set "GC_BENCH_JFR_CONFIGURATION=%SAVED_JFR_CONFIGURATION%") else set "GC_BENCH_JFR_CONFIGURATION="
set "SAVED_JAVA_OPTS="
set "SAVED_JAVA_TOOL_OPTIONS="
set "SAVED_UNDERSCORE_JAVA_OPTIONS="
set "SAVED_JFR_CONFIGURATION="
set "HAD_JAVA_OPTS="
set "HAD_JAVA_TOOL_OPTIONS="
set "HAD_UNDERSCORE_JAVA_OPTIONS="
set "HAD_JFR_CONFIGURATION="
if not "%JAVA_LARGE_JFR_RC%"=="0" goto :failed
set "JAVA_LARGE_JFR_RC="
call "%ROOT%tools\process_java_jfr.bat" large
if errorlevel 1 goto :failed

rem Stage 6: build separate reports for the 1 MiB series.
echo.
echo [6/6] Creating large-object comparison tables and charts...
python "%ROOT%tools\summarize.py" "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\go-large.jsonl" "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\dotnet-large.jsonl" "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\java-large.jsonl" -o "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\comparison-large-objects.csv"
if errorlevel 1 goto :failed
python "%ROOT%tools\visualize_results.py" "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\comparison-large-objects.csv" -o "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\report-large-objects" --split-by-scenario --jfr-analysis-dir "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\jfr-analysis" --dotnet-eventpipe-analysis-dir "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\dotnet-eventpipe"
if errorlevel 1 goto :failed

:finish
echo.
echo ============================================================
echo EXPERIMENT COMPLETED
echo Results: %ROOT%results\%BASE_RESULTS_SUBDIR%
echo Main CSV: %ROOT%results\%BASE_RESULTS_SUBDIR%\comparison-all-scenarios.csv
echo Main charts: %ROOT%results\%BASE_RESULTS_SUBDIR%\report-all
echo Java JFR analysis: %ROOT%results\%BASE_RESULTS_SUBDIR%\jfr-analysis
echo .NET EventPipe analysis: %ROOT%results\%BASE_RESULTS_SUBDIR%\dotnet-eventpipe
if /I not "%SKIP_LARGE_OBJECT_SERIES%"=="1" echo Large-object CSV: %ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\comparison-large-objects.csv
echo Experiment metadata: %ROOT%results\%BASE_RESULTS_SUBDIR%\experiment-info.txt
echo ============================================================
echo.
pause
exit /b 0

:failed
echo.
echo ERROR: The experiment stopped because one step failed.
echo Partial results are preserved in: %ROOT%results\%BASE_RESULTS_SUBDIR%
echo Check the last error message and the experiment-info.txt file.
pause
exit /b 1

:preflight_failed
echo.
echo Startup check failed. Review the error above, then press any key to close this window.
pause >nul
exit /b 1
