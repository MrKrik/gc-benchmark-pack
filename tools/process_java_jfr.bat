@echo off
setlocal EnableExtensions
rem Process every JFR pause recording, or only one scenario.
rem Usage: process_java_jfr.bat [scenario]
rem Example: process_java_jfr.bat transient

for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "RESULTS_DIR=%ROOT%\results"
if defined RESULTS_SUBDIR set "RESULTS_DIR=%RESULTS_DIR%\%RESULTS_SUBDIR%"
set "SOURCE=%RESULTS_DIR%\jfr"
set "OUT=%RESULTS_DIR%\jfr-analysis"

where python >nul 2>nul
if errorlevel 1 (
  echo ERROR: Python 3 was not found in PATH.
  exit /b 1
)
where jfr >nul 2>nul
if errorlevel 1 (
  echo ERROR: jfr was not found in PATH. Add the JDK bin directory to PATH.
  exit /b 1
)
if not exist "%SOURCE%\*.jfr" (
  echo ERROR: No JFR files found in "%SOURCE%".
  echo Run tools\run_java_jfr.bat first.
  exit /b 1
)

if "%~1"=="" (
  python "%ROOT%\tools\jfr_pause_batch.py" "%SOURCE%" --out "%OUT%"
) else (
  python "%ROOT%\tools\jfr_pause_batch.py" "%SOURCE%" --out "%OUT%" --scenario "%~1"
)
exit /b %ERRORLEVEL%
