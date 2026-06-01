# End-to-end reproduction + fix verification (Windows / PowerShell).
#   client -> NGINX(:4088) -> Java proxy(:4001 naive / :4002 fixed) -> Uvicorn(:4000)
#
# Proves: Uvicorn=1 TE, NAIVE proxy=2 TE -> NGINX 502, FIXED proxy=1 TE -> NGINX 200.
# Prereq: run scripts\setup.ps1 once first.
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\reproduce.ps1
$ErrorActionPreference = "Stop"

$root     = Split-Path -Parent $PSScriptRoot
$py       = Join-Path $root ".venv\Scripts\python.exe"
$errLog   = Join-Path $root "nginx-1.31.1\logs\error.log"
$runNginx = Join-Path $PSScriptRoot "run-nginx.ps1"
$java     = (Get-Command java -ErrorAction SilentlyContinue).Source
$curlExe  = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source

if (-not (Test-Path $py))    { Write-Error "venv not found -- run scripts\setup.ps1 first"; exit 1 }
if (-not $java)              { Write-Error "java not found in PATH"; exit 1 }
if (-not $curlExe)           { Write-Error "curl.exe not found in PATH"; exit 1 }

$script:uv    = $null
$script:proxy = $null

function Stop-Proc([System.Diagnostics.Process]$p) {
    if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
}

function Wait-Port([int]$port, [string]$path = "/") {
    for ($i = 0; $i -lt 80; $i++) {
        & $curlExe -s -o NUL "http://127.0.0.1:$port$path" 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Count-TE([string]$url) {
    $out = & $curlExe -s -D - -N -o NUL $url 2>$null
    return ([regex]::Matches(($out -join "`n"), '(?im)^Transfer-Encoding:')).Count
}

function Http-Status([string]$url) {
    return (& $curlExe -s -o NUL -w "%{http_code}" $url 2>$null)
}

function New-TempLog([string]$prefix) {
    return (Join-Path ([IO.Path]::GetTempPath()) ("{0}-{1}.log" -f $prefix, [Guid]::NewGuid().ToString("N")))
}

try {
    # ---- Uvicorn :4000 ----
    Write-Host "==> starting Uvicorn :4000"
    $script:uv = Start-Process -FilePath $py `
        -ArgumentList @("-m","uvicorn","app:app","--app-dir","python-app","--host","127.0.0.1","--port","4000","--log-level","warning") `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardOutput (New-TempLog "uv-out") -RedirectStandardError (New-TempLog "uv-err")
    if (-not (Wait-Port 4000 "/plain")) { throw "uvicorn failed to start" }
    $u = Count-TE "http://127.0.0.1:4000/sse"
    Write-Host ("    [1] Uvicorn direct           Transfer-Encoding count = {0}   (expect 1)" -f $u)

    # ---- NAIVE proxy :4001 ----
    Write-Host "==> starting NAIVE proxy :4001"
    $script:proxy = Start-Process -FilePath $java `
        -ArgumentList @((Join-Path $root "java-proxy\NaiveProxy.java")) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardOutput (New-TempLog "naive-out") -RedirectStandardError (New-TempLog "naive-err")
    if (-not (Wait-Port 4001 "/sse")) { throw "naive proxy failed to start" }
    $n = Count-TE "http://127.0.0.1:4001/sse"
    Write-Host ("    [2] Through NAIVE proxy      Transfer-Encoding count = {0}   (expect 2)" -f $n)

    # ---- NGINX :4088 -> :4001 ----
    Write-Host "==> starting NGINX :4088 (-> naive :4001)"
    if (Test-Path $errLog) { Clear-Content $errLog } else { New-Item -ItemType File -Path $errLog -Force | Out-Null }
    Start-Process powershell -ArgumentList @("-NoProfile","-File",$runNginx,"start") -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 1
    $s1 = Http-Status "http://127.0.0.1:4088/sse"
    Write-Host ("    [3] NGINX -> NAIVE           HTTP status = {0}          (expect 502)" -f $s1)
    $logLine = (Get-Content $errLog -ErrorAction SilentlyContinue |
        Select-String "duplicate header line" | Select-Object -Last 1).Line
    if ($logLine) { $logLine = $logLine -replace '^[0-9/ :]*','' }
    Write-Host ("        log: {0}" -f $(if ($logLine) { $logLine } else { "<no match>" }))

    # ---- swap to FIXED proxy :4002 ----
    Write-Host "==> swapping NAIVE -> FIXED proxy on :4002"
    Stop-Proc $script:proxy; $script:proxy = $null
    Start-Sleep -Seconds 1

    $script:proxy = Start-Process -FilePath $java `
        -ArgumentList @((Join-Path $root "java-proxy\FixedProxy.java")) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardOutput (New-TempLog "fixed-out") -RedirectStandardError (New-TempLog "fixed-err")
    if (-not (Wait-Port 4002 "/sse")) { throw "fixed proxy failed to start" }

    # Reload nginx pointing at :4002
    $confPath = Join-Path $root "nginx\sse.conf"
    $confOrig = Get-Content $confPath -Raw
    $confFixed = $confOrig -replace 'proxy_pass http://127\.0\.0\.1:4001', 'proxy_pass http://127.0.0.1:4002'
    Set-Content $confPath $confFixed -NoNewline
    & powershell -NoProfile -File $runNginx stop | Out-Null
    Start-Sleep -Seconds 1
    Start-Process powershell -ArgumentList @("-NoProfile","-File",$runNginx,"start") -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 1

    $s2 = Http-Status "http://127.0.0.1:4088/sse"
    Write-Host ("    [4] NGINX -> FIXED           HTTP status = {0}          (expect 200)" -f $s2)

    # Restore nginx config
    Set-Content $confPath $confOrig -NoNewline

    Write-Host ""
    Write-Host "==================================== RESULT ===================================="
    if ($u -eq 1 -and $n -eq 2 -and $s1 -eq "502" -and $s2 -eq "200") {
        Write-Host "PASS  uvicorn=1 TE | naive=2 TE -> nginx 502 | fixed=1 TE -> nginx 200"
    } else {
        Write-Host ("CHECK uvicorn={0} naive={1} nginx(naive)={2} nginx(fixed)={3}" -f $u,$n,$s1,$s2)
    }
    Write-Host "================================================================================"
}
finally {
    Stop-Proc $script:proxy
    Stop-Proc $script:uv
    if (Test-Path $runNginx) { & powershell -NoProfile -File $runNginx stop 2>$null | Out-Null }
}
