@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "GC_BENCH_JAVA_CONFIGURATION=java-jfr-diagnostic"
if defined GC_BENCH_JFR_CONFIGURATION set "GC_BENCH_JAVA_CONFIGURATION=%GC_BENCH_JFR_CONFIGURATION%"

rem Run repeated Java GC tests and save one JFR recording per process.
rem Existing results for the same scenario are preserved unless the user confirms overwrite.
rem Usage: run_java_jfr.bat <scenario> [runs] [items] [batches] [payload]
rem Example: run_java_jfr.bat transient 10 10000 1000 128

if "%~1"=="" goto :usage
set "SCENARIO=%~1"
set "RUNS=%~2"
set "ITEMS=%~3"
set "BATCHES=%~4"
set "PAYLOAD=%~5"
if not defined RUNS set "RUNS=10"
if not defined ITEMS set "ITEMS=10000"
if not defined BATCHES set "BATCHES=1000"
if not defined PAYLOAD set "PAYLOAD=128"
if not defined WARMUP_BATCHES set "WARMUP_BATCHES=50"
if not defined GC_BENCH_EXPECTED_REPETITIONS set "GC_BENCH_EXPECTED_REPETITIONS=%RUNS%"

if /I not "%SCENARIO%"=="transient" if /I not "%SCENARIO%"=="retained" if /I not "%SCENARIO%"=="graph" if /I not "%SCENARIO%"=="large" if /I not "%SCENARIO%"=="mixed" (
  echo ERROR: unknown scenario "%SCENARIO%".
  goto :usage_error
)
for %%V in (RUNS ITEMS BATCHES PAYLOAD WARMUP_BATCHES) do call :check_integer "%%V" || goto :usage_error
if %RUNS% LSS 1 goto :usage_error

for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "JAVA_DIR=%ROOT%\java"
set "RESULTS_DIR=%ROOT%\results"
if defined RESULTS_SUBDIR set "RESULTS_DIR=%RESULTS_DIR%\%RESULTS_SUBDIR%"
set "JFR_DIR=%RESULTS_DIR%\jfr"
set "OUTFILE=%RESULTS_DIR%\java-%SCENARIO%-jfr.jsonl"
if not exist "%RESULTS_DIR%" mkdir "%RESULTS_DIR%"
if not exist "%JFR_DIR%" mkdir "%JFR_DIR%"

where javac >nul 2>nul || (echo ERROR: javac not found in PATH. Install a JDK.& exit /b 1)
where java >nul 2>nul || (echo ERROR: java not found in PATH. Install a JDK.& exit /b 1)
where jfr >nul 2>nul || (echo ERROR: jfr not found in PATH. Add the JDK bin directory to PATH.& exit /b 1)
for /f "tokens=2" %%V in ('javac -version 2^>^&1') do set "JDK_VERSION=%%V"
for /f "tokens=1 delims=." %%V in ("%JDK_VERSION%") do set "JDK_MAJOR=%%V"
if not defined JDK_MAJOR (
  echo ERROR: Could not determine the JDK version.
  exit /b 1
)
if %JDK_MAJOR% LSS 21 (
  echo ERROR: JDK 21 or newer is required; found javac %JDK_VERSION%.
  exit /b 1
)

rem Compile before asking to replace prior results, so a compilation error
rem cannot cause the previous successful series to be deleted.
pushd "%JAVA_DIR%" || exit /b 1
javac GcBench.java
if errorlevel 1 (popd & exit /b 1)
popd

rem Avoid mixing stale JFR files from an older run count or parameters.
set "OLD_RESULTS="
if exist "%OUTFILE%" set "OLD_RESULTS=1"
for %%F in ("%JFR_DIR%\java-%SCENARIO%-run-*.jfr") do if exist "%%~fF" set "OLD_RESULTS=1"
if defined OLD_RESULTS (
  echo Existing JSONL/JFR results for scenario "%SCENARIO%" were found.
  choice /C YN /M "Overwrite these results and start a fresh series"
  if errorlevel 2 (
    echo Cancelled. Existing files were not changed.
    exit /b 3
  )
  if exist "%OUTFILE%" del /q "%OUTFILE%"
  for %%F in ("%JFR_DIR%\java-%SCENARIO%-run-*.jfr") do if exist "%%~fF" del /q "%%~fF"
)

pushd "%JAVA_DIR%" || exit /b 1
(type nul) > "%OUTFILE%"
echo Scenario : %SCENARIO%
echo Runs     : %RUNS%
echo Items    : %ITEMS%
echo Batches  : %BATCHES%
echo Payload  : %PAYLOAD%
echo Warm-up  : %WARMUP_BATCHES%
echo JSONL    : %OUTFILE%
echo JFR dir  : %JFR_DIR%
echo.

for /l %%I in (1,1,%RUNS%) do (
  echo [%%I/%RUNS%] Java / %SCENARIO% with JFR
  java %JAVA_OPTS% -cp . GcBench --scenario %SCENARIO% --warmup-batches %WARMUP_BATCHES% --batches %BATCHES% --items %ITEMS% --payload %PAYLOAD% --jfr-file "%JFR_DIR%\java-%SCENARIO%-run-%%I.jfr" >> "%OUTFILE%"
  if errorlevel 1 (
    echo ERROR: Java test failed during run %%I.
    popd
    exit /b 1
  )
)
popd

echo.
echo JFR recordings created. To export pause details, run:
echo python tools\jfr_pause_report.py results\jfr\java-%SCENARIO%-run-1.jfr -o results\jfr\java-%SCENARIO%-run-1-pauses.csv
exit /b 0

:check_integer
set "CHECK_VALUE="
call set "CHECK_VALUE=%%%~1%%"
if not defined CHECK_VALUE exit /b 1
for /f "delims=0123456789" %%A in ("%CHECK_VALUE%") do exit /b 1
exit /b 0

:usage
echo Usage: %~nx0 ^<scenario^> [runs] [items] [batches] [payload]
echo Example: %~nx0 transient 10 10000 1000 128
:usage_error
exit /b 2
