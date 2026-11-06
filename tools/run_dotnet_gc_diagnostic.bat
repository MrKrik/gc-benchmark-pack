@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Usage: run_dotnet_gc_diagnostic.bat <results-subdir> [runs] [items] [batches] [payload] [warmup]
if "%~1"=="" goto :usage
set "RESULTS_SUBDIR=%~1"
set "RUNS=%~2"
set "ITEMS=%~3"
set "BATCHES=%~4"
set "PAYLOAD=%~5"
set "WARMUP_BATCHES=%~6"
set "SCENARIO=%~7"
if not defined RUNS set "RUNS=10"
if not defined ITEMS set "ITEMS=10000"
if not defined BATCHES set "BATCHES=1000"
if not defined PAYLOAD set "PAYLOAD=128"
if not defined WARMUP_BATCHES set "WARMUP_BATCHES=50"
if not defined SCENARIO set "SCENARIOS=transient retained graph large mixed"
if defined SCENARIO set "SCENARIOS=%SCENARIO%"

for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "TRACE_TOOL="
for /f "delims=" %%T in ('where dotnet-trace 2^>nul') do if not defined TRACE_TOOL set "TRACE_TOOL=%%T"
if not defined TRACE_TOOL if exist "%USERPROFILE%\.dotnet\tools\dotnet-trace.exe" set "TRACE_TOOL=%USERPROFILE%\.dotnet\tools\dotnet-trace.exe"
if not defined TRACE_TOOL (
  echo ERROR: dotnet-trace is required for separate .NET EventPipe diagnostics.
  echo Install it with: dotnet tool install --global dotnet-trace
  exit /b 1
)

set "OUTPUT_DIR=%ROOT%\results\%RESULTS_SUBDIR%\dotnet-eventpipe"
if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"
if errorlevel 1 exit /b 1

pushd "%ROOT%\tools\dotnet_gc_trace" || exit /b 1
dotnet build -c Release --nologo
if errorlevel 1 (
  popd
  exit /b 1
)
popd

if exist "%OUTPUT_DIR%\diagnostic-info.txt" (
  for %%C in ("Runs per scenario: %RUNS%" "Items: %ITEMS%" "Batches: %BATCHES%" "Payload bytes: %PAYLOAD%" "Warm-up batches: %WARMUP_BATCHES%") do (
    findstr /X /L /C:%%C "%OUTPUT_DIR%\diagnostic-info.txt" >nul
    if errorlevel 1 (
      echo ERROR: Existing EventPipe diagnostics use different parameters.
      echo Refusing to combine or reuse traces from another configuration.
      exit /b 1
    )
  )
) else (
  (
    echo Diagnostic mode: EventPipe GC events; not included in timed benchmark results.
    echo Runs per scenario: %RUNS%
    echo Items: %ITEMS%
    echo Batches: %BATCHES%
    echo Payload bytes: %PAYLOAD%
    echo Warm-up batches: %WARMUP_BATCHES%
    echo Scenarios: %SCENARIOS%
    echo Providers: Microsoft-Windows-DotNETRuntime GC keyword and GC.Bench interval markers.
    echo .NET SDKs:
    dotnet --list-sdks
  ) > "%OUTPUT_DIR%\diagnostic-info.txt" 2>&1
)

for %%S in (%SCENARIOS%) do (
  for /l %%R in (1,1,%RUNS%) do (
    set "TRACE_FILE=%OUTPUT_DIR%\%%S-run-%%R.nettrace"
    set "EVENT_FILE=%OUTPUT_DIR%\%%S-run-%%R.events.jsonl"
    set "STATUS_FILE=%OUTPUT_DIR%\%%S-run-%%R.events.status.json"
    echo [EventPipe %%R/%RUNS%] .NET / %%S
    if not exist "!TRACE_FILE!" (
      "%TRACE_TOOL%" collect --buffersize 64 --providers Microsoft-Windows-DotNETRuntime:0x1:5,GC.Bench:0xFFFFFFFF:5 --output "!TRACE_FILE!" --show-child-io -- dotnet "%ROOT%\dotnet\GC.Bench\bin\Release\net10.0\GC.Bench.dll" --diagnostic-markers --scenario %%S --warmup-batches %WARMUP_BATCHES% --batches %BATCHES% --items %ITEMS% --payload %PAYLOAD%
      if errorlevel 1 (
        echo ERROR: .NET EventPipe collection failed for %%S repetition %%R.
        exit /b 1
      )
    ) else (
      echo Reprocessing preserved EventPipe trace: !TRACE_FILE!
    )
    if not exist "!TRACE_FILE!" (
      echo ERROR: EventPipe trace is missing: !TRACE_FILE!
      exit /b 1
    )
    dotnet "%ROOT%\tools\dotnet_gc_trace\bin\Release\net10.0\DotnetGcTrace.dll" "!TRACE_FILE!" "!EVENT_FILE!" > "!STATUS_FILE!"
    if errorlevel 1 (
      echo ERROR: EventPipe trace is incomplete for %%S repetition %%R. See !STATUS_FILE!
      exit /b 1
    )
  )
)

python "%ROOT%\tools\summarize_dotnet_gc_trace.py" "%OUTPUT_DIR%"
if errorlevel 1 exit /b 1
echo .NET EventPipe diagnostics saved to "%OUTPUT_DIR%"
exit /b 0

:usage
echo Usage: %~nx0 ^<results-subdir^> [runs] [items] [batches] [payload] [warmup-batches] [scenario]
exit /b 2
