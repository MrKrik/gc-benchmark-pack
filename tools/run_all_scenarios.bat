@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Usage: run_all_scenarios.bat [runs] [items] [batches] [payload]
rem Runs every Go, .NET and Java scenario, then creates CSV and HTML reports.

set "RUNS=%~1"
set "ITEMS=%~2"
set "BATCHES=%~3"
set "PAYLOAD=%~4"

if not defined RUNS set "RUNS=10"
if not defined ITEMS set "ITEMS=10000"
if not defined BATCHES set "BATCHES=1000"
if not defined PAYLOAD set "PAYLOAD=128"
if not defined WARMUP_BATCHES set "WARMUP_BATCHES=50"

for /f "delims=0123456789" %%A in ("%RUNS%") do goto :invalid_parameters
for /f "delims=0123456789" %%A in ("%ITEMS%") do goto :invalid_parameters
for /f "delims=0123456789" %%A in ("%BATCHES%") do goto :invalid_parameters
for /f "delims=0123456789" %%A in ("%PAYLOAD%") do goto :invalid_parameters
for /f "delims=0123456789" %%A in ("%WARMUP_BATCHES%") do goto :invalid_parameters
if %RUNS% LSS 1 goto :invalid_parameters
if %ITEMS% LSS 1 goto :invalid_parameters
if %BATCHES% LSS 1 goto :invalid_parameters

for %%I in ("%~dp0..") do set "ROOT=%%~fI"
if not defined RESULTS_SUBDIR set "RESULTS_SUBDIR=run_manual_%RANDOM%_%RANDOM%"
set "RESULTS=%ROOT%\results\%RESULTS_SUBDIR%"
if not defined GC_BENCH_SESSION_ID set "GC_BENCH_SESSION_ID=%RESULTS_SUBDIR%"
if not exist "%RESULTS%" mkdir "%RESULTS%"

where python >nul 2>nul
if errorlevel 1 (
    echo ERROR: Python was not found in PATH.
    exit /b 1
)

rem Build each runtime once, then randomize the platform order for every repetition.
call :build_go
if errorlevel 1 exit /b 1
call :build_net
if errorlevel 1 exit /b 1
call :build_java
if errorlevel 1 exit /b 1

set "GC_BENCH_SKIP_BUILD=1"
set "GC_BENCH_APPEND_RESULTS=1"
set "GC_BENCH_EXPECTED_REPETITIONS=%RUNS%"
for %%S in (transient retained graph large mixed) do (
    echo.
    echo === Scenario: %%S ===
    for %%P in (go dotnet java) do (
        (type nul) > "%RESULTS%\%%P-%%S.jsonl"
        if errorlevel 1 exit /b 1
    )
    for /l %%I in (1,1,%RUNS%) do (
        set /a ORDER=!RANDOM! %% 6
        call :run_permutation !ORDER! %%S %%I
        if errorlevel 1 exit /b 1
    )
)
set "GC_BENCH_SKIP_BUILD="
set "GC_BENCH_APPEND_RESULTS="

echo.
echo === Combining JSONL results ===
set "JSON_FILES="
for %%P in (go dotnet java) do (
    for %%S in (transient retained graph large mixed) do (
        set "JSON_FILES=!JSON_FILES! "%RESULTS%\%%P-%%S.jsonl""
    )
)

python "%ROOT%\tools\summarize.py" !JSON_FILES! -o "%RESULTS%\comparison-all-scenarios.csv"
if errorlevel 1 (
    echo ERROR: Result collection failed.
    exit /b 1
)

echo.
echo === Creating charts and reports ===
python "%ROOT%\tools\visualize_results.py" "%RESULTS%\comparison-all-scenarios.csv" -o "%RESULTS%\report-all" --split-by-scenario
if errorlevel 1 (
    echo ERROR: Report generation failed.
    exit /b 1
)

echo.
echo Completed all scenarios.
echo CSV: %RESULTS%\comparison-all-scenarios.csv
echo Reports: %RESULTS%\report-all
exit /b 0

:run_one
echo [run %3/%RUNS%] %1 / %2
call "%~dp0run_repeat.bat" %1 %2 1 %ITEMS% %BATCHES% %PAYLOAD%
set "RUN_RC=!ERRORLEVEL!"
if not "!RUN_RC!"=="0" (
    echo ERROR: %1 / %2 failed during repetition %3.
    exit /b !RUN_RC!
)
exit /b 0

:run_permutation
set "GC_BENCH_REPETITION=%3"
if "%1"=="0" (
    set "GC_BENCH_RUN_ORDER=go,dotnet,java"
    call :run_one go %2 %3
    if errorlevel 1 exit /b 1
    call :run_one dotnet %2 %3
    if errorlevel 1 exit /b 1
    call :run_one java %2 %3
    exit /b !ERRORLEVEL!
)
if "%1"=="1" (
    set "GC_BENCH_RUN_ORDER=go,java,dotnet"
    call :run_one go %2 %3
    if errorlevel 1 exit /b 1
    call :run_one java %2 %3
    if errorlevel 1 exit /b 1
    call :run_one dotnet %2 %3
    exit /b !ERRORLEVEL!
)
if "%1"=="2" (
    set "GC_BENCH_RUN_ORDER=dotnet,go,java"
    call :run_one dotnet %2 %3
    if errorlevel 1 exit /b 1
    call :run_one go %2 %3
    if errorlevel 1 exit /b 1
    call :run_one java %2 %3
    exit /b !ERRORLEVEL!
)
if "%1"=="3" (
    set "GC_BENCH_RUN_ORDER=dotnet,java,go"
    call :run_one dotnet %2 %3
    if errorlevel 1 exit /b 1
    call :run_one java %2 %3
    if errorlevel 1 exit /b 1
    call :run_one go %2 %3
    exit /b !ERRORLEVEL!
)
if "%1"=="4" (
    set "GC_BENCH_RUN_ORDER=java,go,dotnet"
    call :run_one java %2 %3
    if errorlevel 1 exit /b 1
    call :run_one go %2 %3
    if errorlevel 1 exit /b 1
    call :run_one dotnet %2 %3
    exit /b !ERRORLEVEL!
)
if "%1"=="5" (
    set "GC_BENCH_RUN_ORDER=java,dotnet,go"
    call :run_one java %2 %3
    if errorlevel 1 exit /b 1
    call :run_one dotnet %2 %3
    if errorlevel 1 exit /b 1
    call :run_one go %2 %3
    exit /b !ERRORLEVEL!
)
echo ERROR: invalid randomized platform order %1.
exit /b 1

:build_go
where go >nul 2>nul
if errorlevel 1 (
    echo ERROR: Go was not found in PATH.
    exit /b 1
)
pushd "%ROOT%\go" || exit /b 1
go build -o gcbench.exe .
set "BUILD_RC=%ERRORLEVEL%"
popd
if not "%BUILD_RC%"=="0" exit /b 1
exit /b 0

:build_net
where dotnet >nul 2>nul
if errorlevel 1 (
    echo ERROR: .NET SDK was not found in PATH.
    exit /b 1
)
dotnet --list-sdks | findstr /R /C:"^10\." >nul
if errorlevel 1 (
    echo ERROR: .NET 10 SDK was not found.
    dotnet --list-sdks
    exit /b 1
)
pushd "%ROOT%\dotnet\GC.Bench" || exit /b 1
set "SAVED_PLATFORM=%PLATFORM%"
set "PLATFORM="
dotnet build -c Release --nologo
set "BUILD_RC=%ERRORLEVEL%"
set "PLATFORM=%SAVED_PLATFORM%"
set "SAVED_PLATFORM="
popd
if not "%BUILD_RC%"=="0" exit /b 1
exit /b 0

:build_java
where javac >nul 2>nul
if errorlevel 1 (
    echo ERROR: javac was not found in PATH.
    exit /b 1
)
where java >nul 2>nul
if errorlevel 1 (
    echo ERROR: java was not found in PATH.
    exit /b 1
)
pushd "%ROOT%\java" || exit /b 1
javac GcBench.java
set "BUILD_RC=%ERRORLEVEL%"
popd
if not "%BUILD_RC%"=="0" exit /b 1
exit /b 0

:invalid_parameters
echo ERROR: runs, items and batches must be positive integers; payload and warm-up batches must be non-negative integers.
exit /b 2
