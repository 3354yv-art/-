@echo off
chcp 65001 >nul
:: דורש הרשאות מנהל (פורט 53 ושינוי DNS)
net session >nul 2>&1 || (powershell -Command "Start-Process '%~f0' -Verb RunAs" & exit /b)
cd /d "%~dp0"
python adblock.py update
python adblock.py set-dns
echo.
echo החוסם פעיל. השאר חלון זה פתוח. סגירה עם Ctrl+C תחזיר את ה-DNS.
python adblock.py run
python adblock.py restore-dns
pause
