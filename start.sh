#!/bin/sh
# הפעלה ב-Linux / macOS
cd "$(dirname "$0")" && exec python3 adb_studio.py "$@"
