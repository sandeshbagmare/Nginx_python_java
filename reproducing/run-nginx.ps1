# Start/stop nginx for this repro, reusing the binary downloaded into ../nginx-1.31.1.
param([string]$Action = "start")
$here  = $PSScriptRoot
$nginx = Join-Path (Split-Path -Parent $here) "nginx-1.31.1"
$conf  = Join-Path $here "sse.conf"
$exe   = Join-Path $nginx "nginx.exe"
if (-not (Test-Path $exe)) { Write-Error "nginx not found at $exe -- run ../scripts/setup.sh first"; exit 1 }
if ($Action -eq "stop") { & $exe -p $nginx -c $conf -s quit; exit }
& $exe -p $nginx -c $conf
