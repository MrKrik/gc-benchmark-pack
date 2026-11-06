@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Usage: run_repeat.bat <go|dotnet|java> <scenario> [runs] [items] [batches] [payload]
rem Run from any current directory; paths are resolved relative to this file.

if "%~1"=="" goto :usage
if "%~2"=="" goto :usage

set "PLATFORM=%~1"
set "SCENARIO=%~2"
set "RUNS=%~3"
set "ITEMS=%~4"
set "BATCHES=%~5"
set "PAYLOAD=%~6"

if not defined RUNS set "RUNS=10"
if not defined ITEMS set "ITEMS=10000"
if not defined BATCHES set "BATCHES=1000"
if not defined PAYLOAD set "PAYLOAD=128"
if not defined WARMUP_BATCHES set "WARMUP_BATCHES=10"
if not defined GC_BENCH_EXPECTED_REPETITIONS set "GC_BENCH_EXPECTED_REPETITIONS=%RUNS%"

if /I not "%PLATFORM%"=="go" if /I not "%PLATFORM%"=="dotnet" if /I not "%PLATFORM%"=="java" (
    echo ERROR: platform must be go, dotnet or java.
    goto :usage_error
)

if /I not "%SCENARIO%"=="transient" if /I not "%SCENARIO%"=="retained" if /I not "%SCENARIO%"=="graph" if /I not "%SCENARIO%"=="large" if /I not "%SCENARIO%"=="mixed" (
    echo ERROR: unknown scenario "%SCENARIO%".
    goto :usage_error
)

rem Basic numeric validation (digits only). Ranges are checked by the test programs.
for %%V in (RUNS ITEMS BATCHES PAYLOAD WARMUP_BATCHES) do call :check_integer "%%V" || goto :usage_error
if %RUNS% LSS 1 (
    echo ERROR: runs must be at least 1.
    goto :usage_error
)

for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "RESULTS_DIR=%ROOT%\results"
if defined RESULTS_SUBDIR set "RESULTS_DIR=%RESULTS_DIR%\%RESULTS_SUBDIR%"
if not exist "%RESULTS_DIR%" mkdir "%RESULTS_DIR%"
if errorlevel 1 goto :failed
set "OUTFILE=%RESULTS_DIR%\%PLATFORM%-%SCENARIO%.jsonl"

if /I "%GC_BENCH_SKIP_BUILD%"=="1" goto :start_runs

rem Build the selected test program once before repeated measurements.
if /I "%PLATFORM%"=="go" goto :build_go
if /I "%PLATFORM%"=="dotnet" goto :build_dotnet
if /I "%PLATFORM%"=="java" call :build_java
if /I "%PLATFORM%"=="java" if errorlevel 1 goto :failed
if /I "%PLATFORM%"=="java" goto :start_runs

goto :usage_error

:build_go
where go >nul 2>nul
if errorlevel 1 (
    echo ERROR: Go was not found in PATH. Install Go and reopen the terminal.
    goto :failed
)
pushd "%ROOT%\go" || goto :failed
go build -o gcbench.exe .
set "BUILD_RC=%ERRORLEVEL%"
popd
if not "%BUILD_RC%"=="0" goto :failed

goto :start_runs

:build_dotnet
where dotnet >nul 2>nul
if errorlevel 1 (
    echo ERROR: .NET SDK was not found in PATH. Install .NET 10 SDK or newer.
    goto :failed
)
dotnet --list-sdks | findstr /R /C:"^10\." >nul
if errorlevel 1 (
    echo ERROR: .NET 10 SDK was not found. Install the .NET 10 SDK and reopen the terminal.
    dotnet --list-sdks
    goto :failed
)
pushd "%ROOT%\dotnet\GC.Bench" || goto :failed
rem Avoid passing the benchmark selector as MSBuild's reserved Platform property.
set "SAVED_PLATFORM=%PLATFORM%"
set "PLATFORM="
dotnet build -c Release --nologo
set "BUILD_RC=%ERRORLEVEL%"
set "PLATFORM=%SAVED_PLATFORM%"
set "SAVED_PLATFORM="
popd
if not "%BUILD_RC%"=="0" goto :failed

goto :start_runs

:build_java
where javac >nul 2>nul
if errorlevel 1 (
    echo ERROR: javac was not found in PATH. Install a JDK, not only a JRE, and reopen the terminal.
    exit /b 1
)
where java >nul 2>nul
if errorlevel 1 (
    echo ERROR: java was not found in PATH. Install a JDK and reopen the terminal.
    exit /b 1
)
pushd "%ROOT%\java" || exit /b 1
javac GcBench.java
set "BUILD_RC=%ERRORLEVEL%"
popd
if not "%BUILD_RC%"=="0" exit /b 1
exit /b 0

:start_runs
if /I "%GC_BENCH_APPEND_RESULTS%"=="1" goto :runs_ready
(type nul) > "%OUTFILE%"
if errorlevel 1 goto :failed

:runs_ready
echo Platform : %PLATFORM%
echo Scenario : %SCENARIO%
echo Runs     : %RUNS%
echo Items    : %ITEMS%
echo Batches  : %BATCHES%
echo Payload  : %PAYLOAD%
echo Warm-up  : %WARMUP_BATCHES%
echo Output   : %OUTFILE%
echo.

for /l %%I in (1,1,%RUNS%) do (
    echo [%%I/%RUNS%] %PLATFORM% / %SCENARIO%
    call :run_one
    if errorlevel 1 goto :run_failed
)

echo.
echo Completed. Results saved to:
echo %OUTFILE%
exit /b 0

:run_one
if /I "%PLATFORM%"=="go" goto :run_go
if /I "%PLATFORM%"=="dotnet" goto :run_dotnet
if /I "%PLATFORM%"=="java" goto :run_java
exit /b 1

:run_go
pushd "%ROOT%\go" || exit /b 1
"%ROOT%\go\gcbench.exe" -scenario %SCENARIO% -warmup-batches %WARMUP_BATCHES% -batches %BATCHES% -items %ITEMS% -payload %PAYLOAD% >> "%OUTFILE%"
set "RUN_RC=%ERRORLEVEL%"
popd
if not "%RUN_RC%"=="0" (
    echo ERROR: Go test process failed with exit code %RUN_RC%.
    exit /b 1
)
exit /b 0

:run_dotnet
pushd "%ROOT%\dotnet\GC.Bench" || exit /b 1
dotnet "bin\Release\net10.0\GC.Bench.dll" --scenario %SCENARIO% --warmup-batches %WARMUP_BATCHES% --batches %BATCHES% --items %ITEMS% --payload %PAYLOAD% >> "%OUTFILE%"
set "RUN_RC=%ERRORLEVEL%"
popd
if not "%RUN_RC%"=="0" (
    echo ERROR: .NET test process failed with exit code %RUN_RC%.
    exit /b 1
)
exit /b 0

:run_java
pushd "%ROOT%\java" || exit /b 1
rem JAVA_OPTS may contain JVM flags separated by spaces, e.g. -Xms512m -Xmx512m -XX:+UseG1GC.
java %JAVA_OPTS% -cp . GcBench --scenario %SCENARIO% --warmup-batches %WARMUP_BATCHES% --batches %BATCHES% --items %ITEMS% --payload %PAYLOAD% >> "%OUTFILE%"
set "RUN_RC=%ERRORLEVEL%"
popd
if not "%RUN_RC%"=="0" (
    echo ERROR: Java test process failed with exit code %RUN_RC%.
    exit /b 1
)
exit /b 0

:check_integer
set "CHECK_VALUE="
call set "CHECK_VALUE=%%%~1%%"
if not defined CHECK_VALUE exit /b 1
for /f "delims=0123456789" %%A in ("%CHECK_VALUE%") do exit /b 1
exit /b 0

:run_failed
echo.
echo ERROR: run failed. See the message above. Partial results, if any, remain in:
echo %OUTFILE%
exit /b 1

:failed
echo.
echo ERROR: build or setup failed. Check the required SDK/JDK and PATH.
exit /b 1

:usage
 echo Usage:
 echo   %~nx0 ^<go^|dotnet^|java^> ^<transient^|retained^|graph^|large^|mixed^> [runs] [items] [batches] [payload]
 echo.
 echo Example:
 echo   %~nx0 go transient 10 10000 1000 128
 echo.
 echo Optional environment variables:
 echo   WARMUP_BATCHES=10
 echo   JAVA_OPTS="-Xms512m -Xmx512m -XX:+UseG1GC"
:usage_error
exit /b 2
