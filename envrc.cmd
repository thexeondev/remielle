@echo off
setlocal EnableExtensions DisableDelayedExpansion
pushd "%~dp0" || exit /b 1

set "ZIG_VERSION=0.16.0"

for /f "delims=" %%V in ('zig version 2^>nul') do (
    if "%%V"=="%ZIG_VERSION%" goto :shell
)

set "ZIG_DIST=zig-x86_64-windows-%ZIG_VERSION%"
set "ZIG_DIR=%CD%\.direnv\%ZIG_DIST%"
set "ZIG_ZIP=%ZIG_DIR%.zip"
set "ZIG_URL=https://ziglang.org/download/%ZIG_VERSION%/%ZIG_DIST%.zip"

if not "%ZIG_VERSION:-dev.=%"=="%ZIG_VERSION%" (
    set "ZIG_URL=https://ziglang.org/builds/%ZIG_DIST%.zip"
)

if not exist "%ZIG_DIR%\zig.exe" (
    if not exist ".direnv" mkdir ".direnv"

    curl.exe -L --fail --progress-bar --ssl-no-revoke ^
        -o "%ZIG_ZIP%" "%ZIG_URL%" || goto :fail

    tar.exe -xf "%ZIG_ZIP%" -C ".direnv" || goto :fail
    if not exist "%ZIG_DIR%\zig.exe" goto :fail

    del /q "%ZIG_ZIP%"
)

set "PATH=%ZIG_DIR%;%PATH%"

:shell
echo Zig %ZIG_VERSION% is ready.
echo.
"%ComSpec%" /d /k
popd
exit /b 0

:fail
if exist "%ZIG_ZIP%" del /q "%ZIG_ZIP%"
if exist "%ZIG_DIR%" rmdir /s /q "%ZIG_DIR%"
rmdir ".direnv" 2>nul

echo Failed to prepare Zig.
pause
popd
exit /b 1