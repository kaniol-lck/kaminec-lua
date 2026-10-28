@echo off
setlocal
rem Kaminec-Lua launcher wrapper.
rem Override LUA / KAMINEC_PROXY via environment if needed.
if not "%LUA%"=="" goto run
where lua >nul 2>nul
if errorlevel 1 (
  echo [Kaminec] Lua 5.4 not found. Install Lua 5.4 and add lua.exe to PATH, or set LUA.
  exit /b 1
)
set "LUA=lua"

:run
if "%KAMINEC_PROXY%"=="" if not "%HTTPS_PROXY%"=="" set "KAMINEC_PROXY=%HTTPS_PROXY%"
"%LUA%" "%~dp0src\main.lua" %*
