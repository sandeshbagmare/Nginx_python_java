# Start/stop native nginx.  Usage:  powershell -File scripts/run-nginx.ps1 [start|stop]
param([string]$Action = "start")

$root   = Split-Path -Parent $PSScriptRoot
$prefix = Join-Path $root "nginx-1.31.1"
$conf   = Join-Path $root "nginx\sse.conf"
$exe    = Join-Path $prefix "nginx.exe"

if (-not (Test-Path $exe)) { Write-Error "nginx not found at $exe -- run scripts/setup.sh first"; exit 1 }

if ($Action -eq "stop") {
    & $exe -p $prefix -c $conf -s quit
    Write-Output "nginx stop signal sent"
} else {
    Write-Output "starting nginx: $exe -p $prefix -c $conf"
    & $exe -p $prefix -c $conf
}
