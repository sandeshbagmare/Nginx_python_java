# Start the FastAPI/Uvicorn app on 127.0.0.1:4000
# Usage:  powershell -File scripts\run-uvicorn.ps1
param()
$root = Split-Path -Parent $PSScriptRoot
$py   = Join-Path $root ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { Write-Error "venv not found -- run scripts\setup.ps1 first"; exit 1 }
Write-Host "[uvicorn] starting on 127.0.0.1:4000"
& $py -m uvicorn app:app --app-dir python-app --host 127.0.0.1 --port 4000 @args
