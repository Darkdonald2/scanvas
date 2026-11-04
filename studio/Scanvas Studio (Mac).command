#!/bin/bash
# Double-click to start Scanvas Studio from source on a Mac (needs Python 3.10-3.12 from python.org).
cd "$(dirname "$0")"
PY=$(command -v python3.12 || command -v python3.11 || command -v python3.10 || command -v python3)
if [ ! -d .venv ]; then
  echo "First start: setting up (a few minutes)…"
  "$PY" -m venv .venv && ./.venv/bin/pip install --upgrade pip && ./.venv/bin/pip install -r requirements.txt || { echo "Setup failed."; read -r; exit 1; }
fi
./.venv/bin/python run_studio.py "$@"
