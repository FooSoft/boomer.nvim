@echo off
rem Windows counterpart of tests/support/fake: stands in for `codex` or
rem `copilot`, ignores the arguments and plays the scenario named by
rem BOOMER_SCENARIO. Like an npm shim, it leaves the agent as a child of cmd.exe.
setlocal
if not defined BOOMER_NVIM set "BOOMER_NVIM=nvim"
"%BOOMER_NVIM%" --clean --headless -l "%~dp0fake.lua" "%BOOMER_SCENARIO%"
exit /b %ERRORLEVEL%
