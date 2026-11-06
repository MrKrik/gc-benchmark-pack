[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('go', 'dotnet', 'java')]
    [string]$Platform,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateSet('transient', 'retained', 'graph', 'large', 'mixed')]
    [string]$Scenario,

    [Parameter(Position = 2)]
    [ValidateRange(1, 100000)]
    [int]$Runs = 10,

    [Parameter(Position = 3)]
    [ValidateRange(1, 100000000)]
    [int]$Items = 10000,

    [Parameter(Position = 4)]
    [ValidateRange(1, 100000000)]
    [int]$Batches = 1000,

    [Parameter(Position = 5)]
    [ValidateRange(0, 100000000)]
    [int]$Payload = 128
)

$ErrorActionPreference = 'Stop'

# Корень набора тестов: на уровень выше каталога tools.
$root = Split-Path -Parent $PSScriptRoot
$resultsDir = Join-Path $root 'results'
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
$outFile = Join-Path $resultsDir ("{0}-{1}.jsonl" -f $Platform, $Scenario)

# Совместимо с Windows PowerShell 5.1: записываем UTF-8 без BOM,
# чтобы JSONL корректно читался Python-скриптом summarize.py.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($outFile, '', $utf8NoBom)

$warmup = 50
if (-not [string]::IsNullOrWhiteSpace($env:WARMUP_BATCHES)) {
    try {
        $warmup = [int]$env:WARMUP_BATCHES
    }
    catch {
        throw "Переменная WARMUP_BATCHES должна быть целым числом. Получено: '$env:WARMUP_BATCHES'"
    }
}
if ($warmup -lt 0) {
    throw 'WARMUP_BATCHES не может быть отрицательной.'
}

function Get-ExecutablePath {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Get-Command $Name -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($command.Source)) {
        throw "Не удалось определить путь к команде '$Name'. Проверьте PATH и установку инструмента."
    }
    return $command.Source
}

function Invoke-BuildCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $Executable @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Команда сборки завершилась с кодом ${LASTEXITCODE}: $Executable $($Arguments -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-RunAndAppend {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$OutputFile
    )

    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.stdout')
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.stderr')

    try {
        $process = Start-Process -FilePath $Executable `
            -ArgumentList $Arguments `
            -WorkingDirectory $WorkingDirectory `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        if (Test-Path $stdoutFile) {
            $stdoutText = [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8)
            [System.IO.File]::AppendAllText($OutputFile, $stdoutText, $utf8NoBom)
        }

        if ($process.ExitCode -ne 0) {
            $stderrText = ''
            if (Test-Path $stderrFile) {
                $stderrText = [System.IO.File]::ReadAllText($stderrFile, [System.Text.Encoding]::UTF8)
            }
            throw "Тест завершился с кодом $($process.ExitCode). $stderrText"
        }
    }
    finally {
        Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

switch ($Platform) {
    'go' {
        $goDir = Join-Path $root 'go'
        $goExe = Get-ExecutablePath 'go'
        Invoke-BuildCommand -Executable $goExe -Arguments @('build', '-o', 'gcbench.exe', '.') -WorkingDirectory $goDir
        $testExe = Join-Path $goDir 'gcbench.exe'
        $nativeArgs = @(
            '-scenario', $Scenario,
            '-warmup-batches', "$warmup",
            '-batches', "$Batches",
            '-items', "$Items",
            '-payload', "$Payload"
        )
        $workingDir = $goDir
    }

    'dotnet' {
        $dotnetDir = Join-Path $root 'dotnet/GC.Bench'
        $dotnetExe = Get-ExecutablePath 'dotnet'
        $installedSdks = @(& $dotnetExe --list-sdks)
        if ($LASTEXITCODE -ne 0 -or -not ($installedSdks | Where-Object { $_ -match '^10\.' })) {
            throw "Не найден .NET 10 SDK. Установите .NET 10 SDK и проверьте команду 'dotnet --list-sdks'. Найденные SDK: $($installedSdks -join '; ')"
        }
        Invoke-BuildCommand -Executable $dotnetExe -Arguments @('build', '-c', 'Release', '--nologo') -WorkingDirectory $dotnetDir
        $testExe = $dotnetExe
        $nativeArgs = @(
            'bin/Release/net10.0/GC.Bench.dll',
            '--scenario', $Scenario,
            '--warmup-batches', "$warmup",
            '--batches', "$Batches",
            '--items', "$Items",
            '--payload', "$Payload"
        )
        $workingDir = $dotnetDir
    }

    'java' {
        $javaDir = Join-Path $root 'java'
        $javacExe = Get-ExecutablePath 'javac'
        $javaExe = Get-ExecutablePath 'java'
        Invoke-BuildCommand -Executable $javacExe -Arguments @('GcBench.java') -WorkingDirectory $javaDir

        # JAVA_OPTS поддерживает обычные флаги без пробелов внутри одного аргумента,
        # например: -Xms512m -Xmx512m -XX:+UseG1GC.
        $javaOptions = @()
        if (-not [string]::IsNullOrWhiteSpace($env:JAVA_OPTS)) {
            $javaOptions = @($env:JAVA_OPTS -split '\s+' | Where-Object { $_.Length -gt 0 })
        }
        $testExe = $javaExe
        $nativeArgs = @($javaOptions) + @(
            '-cp', '.', 'GcBench',
            '--scenario', $Scenario,
            '--warmup-batches', "$warmup",
            '--batches', "$Batches",
            '--items', "$Items",
            '--payload', "$Payload"
        )
        $workingDir = $javaDir
    }
}

for ($i = 1; $i -le $Runs; $i++) {
    Write-Host ("[{0}/{1}] {2} / {3}" -f $i, $Runs, $Platform, $Scenario)
    Invoke-RunAndAppend -Executable $testExe -Arguments $nativeArgs -WorkingDirectory $workingDir -OutputFile $outFile
}

Write-Host "Saved $Runs runs to $outFile"
