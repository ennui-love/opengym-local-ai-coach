@echo off
setlocal
set "LMS=%USERPROFILE%\.lmstudio\bin\lms.exe"

echo ============================================
echo  Reload LM Studio model with 16K context
echo  (fixes "coach cannot run / cut off" errors)
echo ============================================
echo.

if not exist "%LMS%" (
  echo [ERROR] lms.exe not found at:
  echo   %LMS%
  echo Please open LM Studio at least once, then retry.
  pause
  exit /b 1
)

echo [1/2] Unloading any existing instances...
"%LMS%" unload --all

echo.
echo [2/2] Loading with context 16384, parallel 1...
"%LMS%" load qwen3.5-9b-deepseek-v4-flash -c 16384 --parallel 1 -y

echo.
echo Done. Make sure the Local Server in LM Studio is running on port 1234.
pause
