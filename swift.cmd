@echo off
REM Swift on Windows needs three things that a plain pwsh session lacks:
REM   1. the MSVC headers, libraries and link.exe (vcvars64.bat sets INCLUDE/LIB/PATH)
REM   2. the Windows SDK that ships with the Swift toolchain (SDKROOT)
REM   3. the toolchain and runtime bin directories on PATH
REM cmd.exe is the only shell that can inherit a .bat, so every swift call goes here.
REM
REM All paths are relative to this file (or to %LOCALAPPDATA%), so a fresh clone works
REM on any machine with Visual Studio Build Tools and Swift for Windows installed.
REM Override with SWIFT_ROOT / VCVARS64 before invoking if your layout differs.

setlocal
set "REPO_ROOT=%~dp0"
if not defined VCVARS64 set "VCVARS64=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS64%" (
  echo [swift.cmd] vcvars64.bat not found: "%VCVARS64%"
  echo [swift.cmd] install VS 2022 Build Tools, or set VCVARS64 to its full path.
  exit /b 1
)
call "%VCVARS64%" >nul

if not defined SWIFT_ROOT set "SWIFT_ROOT=%LOCALAPPDATA%\Programs\Swift"
set "SWIFT_BIN=%SWIFT_ROOT%\Toolchains\6.4.3+Asserts\usr\bin"
if not exist "%SWIFT_BIN%\swift.exe" (
  echo [swift.cmd] Swift toolchain not found under "%SWIFT_ROOT%".
  echo [swift.cmd] set SWIFT_ROOT to your Swift installation root.
  exit /b 1
)
set "SWIFT_RT=%SWIFT_ROOT%\Runtimes\6.4.3\usr\bin"
set "SDKROOT=%SWIFT_ROOT%\Platforms\6.4.3\Windows.platform\Developer\SDKs\Windows.sdk"
set "PATH=%SWIFT_BIN%;%SWIFT_RT%;%PATH%"

REM Run from the Swift package directory, wherever this .cmd lives.
cd /d "%REPO_ROOT%PandaPlayCore"
"%SWIFT_BIN%\swift.exe" %*
endlocal & exit /b %ERRORLEVEL%
