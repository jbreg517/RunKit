@echo off
title RunKit Parler voice sampler
set "PY=%LOCALAPPDATA%\rk-tts\parler\Scripts\python.exe"
if exist "%PY%" goto run
echo Parler venv not found at %PY%
echo See tools\voicecues\README.md - Parler environment section - to recreate it.
pause
exit /b 1
:run
cd /d "%~dp0"
echo Starting Parler sampler (model load takes about a minute)...
"%PY%" parler_try.py %*
echo.
echo Finished. Clips are in out\try\
pause
