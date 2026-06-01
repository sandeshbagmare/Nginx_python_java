# One-time setup: Python venv + deps, and the native nginx binary.
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "[setup] creating Python venv + installing deps..."
python -m venv .venv
$py = Join-Path $root ".venv\Scripts\python.exe"
& $py -m pip install --upgrade pip | Out-Null
& $py -m pip install -r python-app\requirements.txt

$nginxVer = "1.31.1"
$nginxDir = Join-Path $root "nginx-$nginxVer"
$nginxExe = Join-Path $nginxDir "nginx.exe"
if (-not (Test-Path $nginxExe)) {
    Write-Host "[setup] downloading nginx $nginxVer (Windows build)..."
    $zip = Join-Path $root "nginx.zip"
    Invoke-WebRequest -Uri "http://nginx.org/download/nginx-$nginxVer.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $root -Force
}

Write-Host "[setup] done."
Write-Host "Next: powershell -ExecutionPolicy Bypass -File scripts\reproduce.ps1"
