@echo off
setlocal EnableExtensions

set "WARN=[WARN]"
set "OK=[OK]"
set "INFO=[INFO]"

set "DEVHOME=%~dp0"
if "%DEVHOME:~-1%"=="\" set "DEVHOME=%DEVHOME:~0,-1%"

set "WORKDIR=%CD%"

set "GIT_EXE="
for /f "delims=" %%A in ('where git.exe 2^>nul') do ( set "GIT_EXE=%%A" & goto :got_git )
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-Command git -ErrorAction SilentlyContinue).Source"`) do ( set "GIT_EXE=%%A" & goto :got_git )

:got_git
if not defined GIT_EXE (
  echo %WARN% git.exe not found. Install Git for Windows or add it to PATH.
  exit /b 2
)

set "GIT_DIR="
for %%I in ("%GIT_EXE%") do set "GIT_DIR=%%~dpI"
if "%GIT_DIR:~-1%"=="\" set "GIT_DIR=%GIT_DIR:~0,-1%"

set "GIT_ROOT=%GIT_DIR%"
for %%I in ("%GIT_ROOT%\..") do set "GIT_ROOT=%%~fI"

set "BASH_EXE="
if exist "%GIT_ROOT%\bin\bash.exe" set "BASH_EXE=%GIT_ROOT%\bin\bash.exe"
if not defined BASH_EXE if exist "%GIT_ROOT%\usr\bin\bash.exe" set "BASH_EXE=%GIT_ROOT%\usr\bin\bash.exe"

if not defined BASH_EXE (
  echo %WARN% Found git at "%GIT_EXE%" but bash.exe not found under "%GIT_ROOT%".
  exit /b 3
)

if not exist "%DEVHOME%\server" (
  echo %WARN% Cannot find server script: "%DEVHOME%\server"
  exit /b 4
)

where docker.exe >nul 2>&1
if errorlevel 1 echo %WARN% docker.exe not found on Windows PATH. If ./server uses docker, it may fail.
if errorlevel 1 goto :run

docker info >nul 2>&1
if errorlevel 1 echo %WARN% Docker installed but NOT running/reachable (docker info failed). Start Docker Desktop / engine.

:run
"%BASH_EXE%" -lc "set -euo pipefail; export TERM=xterm-256color; DEVHOME_WIN=\"$1\"; CALLER_WIN=\"$2\"; DEVHOME=$(cygpath -u \"$DEVHOME_WIN\"); CALLER=$(cygpath -u \"$CALLER_WIN\"); cd \"$DEVHOME\"; chmod +x ./server >/dev/null 2>&1 || true; cd \"$CALLER\"; shift 2; exec \"$DEVHOME/server\" --__win_workdir \"$CALLER_WIN\" \"$@\"" bash "%DEVHOME%" "%WORKDIR%" %*

exit /b %ERRORLEVEL%
