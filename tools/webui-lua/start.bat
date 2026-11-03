@echo off
setlocal
rem Usage: start.bat [lua.exe] [launcher-root]
rem Example: start.bat C:\msys64\mingw64\bin\lua.exe D:\dev\kaminec-spike\.minecraft
set "LUA=%~1"
if "%LUA%"=="" set "LUA=lua.exe"
set "ROOT=%~2"
if "%ROOT%"=="" set "ROOT=.minecraft"
"%LUA%" "%~dp0server.lua" --dir "%ROOT%" --port 8766 --open
if errorlevel 1 pause
