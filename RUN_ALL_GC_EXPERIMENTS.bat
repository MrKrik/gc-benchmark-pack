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
if not defined WARMUP_BATCHES set "WARMUP_BATCHES=10"

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
dotnet --list-sdks | findstr /R /C:"^10\." >nul
if errorlevel 1 (
  echo ERROR: .NET 10 SDK is required. Installed SDKs:
  dotnet --list-sdks
  goto :preflight_failed
)
where javac >nul 2>nul || (echo ERROR: JDK javac not found in PATH.& goto :preflight_failed)
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
  echo.
  echo --- OS ---
  ver
  echo.
  echo --- Go ---
  go version
  echo.
  echo --- .NET SDKs ---
  dotnet --list-sdks
  echo.
  echo --- Java ---
  java -version
  echo.
  echo --- Python ---
  python --version
  echo.
  echo --- CPU and memory ---
  powershell -NoProfile -Command "Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name; 'RAM bytes: ' + (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory"
) > "%RUN_DIR%\experiment-info.txt" 2>&1

 echo.
 echo ============================================================
 echo Full GC experiment
 echo Result folder: results\%BASE_RESULTS_SUBDIR%
 echo Base matrix: 3 platforms x 5 scenarios x %RUNS% repetitions
 echo Java JFR: 5 scenarios x %RUNS% recordings
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
echo [1/5] Running standard benchmark matrix...
set "RESULTS_SUBDIR=%BASE_RESULTS_SUBDIR%"
call "%ROOT%tools\run_all_scenarios.bat" %RUNS% %ITEMS% %BATCHES% %PAYLOAD%
if errorlevel 1 goto :failed

rem Stage 2: Java JFR recordings with the same baseline workload parameters.
echo.
echo [2/5] Recording Java JFR pauses for all five baseline scenarios...
for %%S in (transient retained graph large mixed) do (
  echo.
  echo --- Java JFR: %%S ---
  call "%ROOT%tools\run_java_jfr.bat" %%S %RUNS% %ITEMS% %BATCHES% %PAYLOAD%
  if errorlevel 1 goto :failed
)

rem Stage 3: export Java STW pause events to CSV.
echo.
echo [3/5] Processing baseline Java JFR recordings...
call "%ROOT%tools\process_java_jfr.bat"
if errorlevel 1 goto :failed

echo.
echo === Adding Java JFR analysis to scenario reports ===
python "%ROOT%tools\visualize_results.py" "%ROOT%results\%BASE_RESULTS_SUBDIR%\comparison-all-scenarios.csv" -o "%ROOT%results\%BASE_RESULTS_SUBDIR%\report-all" --split-by-scenario --jfr-analysis-dir "%ROOT%results\%BASE_RESULTS_SUBDIR%\jfr-analysis"
if errorlevel 1 goto :failed

rem Stage 4: targeted 1 MiB object series, kept in a separate subfolder.
if /I "%SKIP_LARGE_OBJECT_SERIES%"=="1" goto :finish

echo.
echo [4/5] Running targeted 1 MiB large-object series...
set "RESULTS_SUBDIR=%BASE_RESULTS_SUBDIR%\large-object-series"
set "GC_BENCH_SESSION_ID=%BASE_RESULTS_SUBDIR%\large-object-series"
call "%ROOT%tools\run_repeat.bat" go large %RUNS% 64 10 1048576
if errorlevel 1 goto :failed
call "%ROOT%tools\run_repeat.bat" dotnet large %RUNS% 64 10 1048576
if errorlevel 1 goto :failed

rem Baseline Java run uses default JVM settings and no JFR, like the other platforms.
set "SAVED_JAVA_OPTS=%JAVA_OPTS%"
set "JAVA_OPTS="
call "%ROOT%tools\run_repeat.bat" java large %RUNS% 64 10 1048576
if errorlevel 1 goto :failed
set "JAVA_OPTS=%SAVED_JAVA_OPTS%"
set "SAVED_JAVA_OPTS="

rem A separately labeled JFR diagnostic uses fixed G1 region settings; do not
rem include it in the uninstrumented cross-platform performance table.
set "JAVA_OPTS=-Xms512m -Xmx512m -XX:+UseG1GC -XX:G1HeapRegionSize=1m"
call "%ROOT%tools\run_java_jfr.bat" large %RUNS% 64 10 1048576
if errorlevel 1 goto :failed
call "%ROOT%tools\process_java_jfr.bat" large
if errorlevel 1 goto :failed

rem Build a separate cross-platform CSV and HTML report for the 1 MiB series.
echo.
echo [5/5] Creating large-object comparison tables and charts...
python "%ROOT%tools\summarize.py" "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\go-large.jsonl" "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\dotnet-large.jsonl" "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\java-large.jsonl" -o "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\comparison-large-objects.csv"
if errorlevel 1 goto :failed
python "%ROOT%tools\visualize_results.py" "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\comparison-large-objects.csv" -o "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\report-large-objects" --split-by-scenario --jfr-analysis-dir "%ROOT%results\%BASE_RESULTS_SUBDIR%\large-object-series\jfr-analysis"
if errorlevel 1 goto :failed

:finish
echo.
echo ============================================================
echo EXPERIMENT COMPLETED
echo Results: %ROOT%results\%BASE_RESULTS_SUBDIR%
echo Main CSV: %ROOT%results\%BASE_RESULTS_SUBDIR%\comparison-all-scenarios.csv
echo Main charts: %ROOT%results\%BASE_RESULTS_SUBDIR%\report-all
echo Java JFR analysis: %ROOT%results\%BASE_RESULTS_SUBDIR%\jfr-analysis
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
