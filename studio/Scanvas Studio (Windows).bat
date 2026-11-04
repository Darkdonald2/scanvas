@echo off
rem Double-click to start Scanvas Studio from source on Windows (needs Python 3.10-3.12 from python.org).
cd /d "%~dp0"
if not exist .venv (
  echo First start: setting up, this takes a few minutes...
  py -3.12 -m venv .venv 2>nul || py -3 -m venv .venv || python -m venv .venv
  .venv\Scripts\python -m pip install --upgrade pip
  .venv\Scripts\python -m pip install -r requirements.txt || (echo Setup failed. & pause & exit /b 1)
)
.venv\Scripts\python run_studio.py %*
if errorlevel 1 pause
