@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Run the standard matrix at several warm-up sizes; each setting is isolated.
rem Usage: run_warmup_sensitivity.bat [runs] [items] [batches] [payload] [warmup-values]

set "RUNS=%~1"
set "ITEMS=%~2"
set "BATCHES=%~3"
set "PAYLOAD=%~4"
set "WARMUPS=%~5"
if not defined RUNS set "RUNS=5"
if not defined ITEMS set "ITEMS=10000"
if not defined BATCHES set "BATCHES=1000"
if not defined PAYLOAD set "PAYLOAD=128"
if not defined WARMUPS set "WARMUPS=0 10 50 100"

for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "BASE_ID=warmup-sensitivity-%RANDOM%-%RANDOM%"

for %%W in (%WARMUPS%) do (
    echo.
    echo === Warm-up batches: %%W ===
    set "WARMUP_BATCHES=%%W"
    set "RESULTS_SUBDIR=%BASE_ID%\warmup_%%W"
    set "GC_BENCH_SESSION_ID=%BASE_ID%-warmup-%%W"
    call "%ROOT%\tools\run_all_scenarios.bat" %RUNS% %ITEMS% %BATCHES% %PAYLOAD%
    if errorlevel 1 (
        echo ERROR: warm-up sensitivity run failed at %%W batches.
        exit /b 1
    )
)

echo.
echo Warm-up sensitivity runs saved under:
echo %ROOT%\results\%BASE_ID%
exit /b 0
