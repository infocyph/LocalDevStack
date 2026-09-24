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

if ($content.Contains('docker info') -or $content.Contains('where docker.exe')) {
    throw "lds.bat must not require Docker for offline-safe commands"
}
Write-Host "PASS: Windows bridge has no unconditional Docker preflight"

$helpOutput = & cmd.exe /d /c ('"' + $batPath + '" help') 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "lds.bat help failed with exit code ${LASTEXITCODE}: $helpOutput"
}
if (($helpOutput -join "`n") -notmatch 'LocalDevStack') {
    throw "lds.bat help did not reach the Bash CLI"
}
Write-Host "PASS: lds.bat help works without wrapper-level Docker checks"

$tempParent = Join-Path $env:RUNNER_TEMP "Local Dev Stack"
New-Item -ItemType Directory -Force -Path $tempParent | Out-Null
Copy-Item -Path $batPath -Destination (Join-Path $tempParent "lds.bat") -Force

$copied = Get-Content -Raw -Path (Join-Path $tempParent "lds.bat")
if (-not $copied.Contains('set "DEVHOME=%~dp0"')) {
    throw "bridge contract was not preserved when copied under a path containing spaces"
}

Write-Host "PASS: Windows bridge quoting/discovery contract"

$ldsPath = Join-Path $root "lds"
$execPath = Join-Path $root "lib/container-exec.sh"
$conversionPath = Join-Path $root "lib/conversion.sh"
if (-not (Test-Path $execPath)) {
    throw "shared container execution helper not found"
}
if (-not (Test-Path $conversionPath)) {
    throw "conversion helper not found"
}
$ldsContent = Get-Content -Raw -Path $ldsPath
$execContent = Get-Content -Raw -Path $execPath
$conversionContent = Get-Content -Raw -Path $conversionPath
foreach ($needle in @(
    'source "$DIR/lib/container-exec.sh"',
    '_is_public_lds_command()'
)) {
    if (-not $ldsContent.Contains($needle)) {
        throw "lds is missing Core/CLI execution contract: $needle"
    }
}
foreach ($needle in @(
    'MSYS_NO_PATHCONV=1',
    "MSYS2_ARG_CONV_EXCL='*'",
    '_container_exec_argv',
    '_container_open_shell'
)) {
    if (-not $execContent.Contains($needle)) {
        throw "shared executor is missing Windows/Git Bash contract: $needle"
    }
}
Write-Host "PASS: Windows bridge uses MSYS-safe shared container execution"

foreach ($needle in @(
    '_convert_docker_mount_path',
    'MSYS_NO_PATHCONV=1',
    "MSYS2_ARG_CONV_EXCL='*'"
)) {
    if (-not $conversionContent.Contains($needle)) {
        throw "conversion is missing Windows/Git Bash contract: $needle"
    }
}
Write-Host "PASS: document conversion uses MSYS-safe host mounts"
