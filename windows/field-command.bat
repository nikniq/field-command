@echo off
REM Runs Field Command from the source tree. Needs: pip install -r requirements.txt
setlocal
set "PYTHONPATH=%~dp0..\linux;%PYTHONPATH%"
python -m fieldcommand %*
endlocal
