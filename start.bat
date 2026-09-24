@echo off
chcp 65001 >nul
title ADB Studio
where py >nul 2>nul && (py -3 "%~dp0adb_studio.py" & goto :eof)
where python >nul 2>nul && (python "%~dp0adb_studio.py" & goto :eof)
echo Python 3 is required: https://www.python.org/downloads/
pause
