$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$batPath = Join-Path $root "lds.bat"

if (-not (Test-Path $batPath)) {
    throw "lds.bat not found"
}

$content = Get-Content -Raw -Path $batPath

$required = @(
    'set "DEVHOME=%~dp0"',
    'set "WORKDIR=%CD%"',
    'where git.exe',
    'Get-Command git',
    '\bin\bash.exe',
    '\usr\bin\bash.exe',
    'cygpath -u',
    '--__win_workdir',
    '"%DEVHOME%" "%WORKDIR%" %*'
)

foreach ($needle in $required) {
    if (-not $content.Contains($needle)) {
        throw "lds.bat is missing expected bridge contract: $needle"
    }
}

# Characterize the existing Docker preflight. Batch 7 will move Docker
# availability checks behind commands that actually require Docker.
if (-not $content.Contains('docker info')) {
    Write-Host "INFO: unconditional Docker preflight is already absent"
} else {
    Write-Host "INFO: current bridge still performs the known unconditional Docker preflight"
}

$tempParent = Join-Path $env:RUNNER_TEMP "Local Dev Stack"
New-Item -ItemType Directory -Force -Path $tempParent | Out-Null
Copy-Item -Path $batPath -Destination (Join-Path $tempParent "lds.bat") -Force

$copied = Get-Content -Raw -Path (Join-Path $tempParent "lds.bat")
if (-not $copied.Contains('set "DEVHOME=%~dp0"')) {
    throw "bridge contract was not preserved when copied under a path containing spaces"
}

Write-Host "PASS: Windows bridge quoting/discovery contract"
