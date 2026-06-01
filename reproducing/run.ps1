# PowerShell end-to-end repro (Windows-friendly) for the duplicate Transfer-Encoding issue.
# client -> NGINX(:4088) -> Tomcat proxy(:4003) -> Uvicorn(:4000)
#
# Usage:  powershell -ExecutionPolicy Bypass -File reproducing\run.ps1
$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
Set-Location $here
$parent = Split-Path -Parent $here

$py = Join-Path $parent ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) {
    $py = Join-Path $parent ".venv\bin\python"
}
if (-not (Test-Path $py)) {
    Write-Error "python not found at $py -- run ..\scripts\setup.ps1 first"
    exit 1
}

$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if (-not $curl) { Write-Error "curl.exe not found in PATH"; exit 1 }

$javac = (Get-Command javac -ErrorAction SilentlyContinue).Source
$java  = (Get-Command java  -ErrorAction SilentlyContinue).Source
if (-not $javac -or -not $java) { Write-Error "javac/java not found in PATH"; exit 1 }

$err      = Join-Path $parent "nginx-1.31.1\logs\error.log"
$cp       = "out;lib/*"
$runNginx = Join-Path $here "run-nginx.ps1"

$script:uv = $null
$script:tc = $null

function Stop-Proc([System.Diagnostics.Process]$p) {
    if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
}

function New-TempLog([string]$prefix) {
    return Join-Path ([IO.Path]::GetTempPath()) ("{0}-{1}.log" -f $prefix, [Guid]::NewGuid().ToString("N"))
}

function Wait-Port([int]$port, [string]$path) {
    for ($i = 0; $i -lt 80; $i++) {
        & $script:curl -s -o NUL "http://127.0.0.1:$port$path" 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Count-TransferEncoding([string]$url) {
    $headers = & $script:curl -s -D - -N -o NUL $url
    return ([regex]::Matches(($headers -join "`n"), '(?im)^Transfer-Encoding:')).Count
}

function Http-Status([string]$url) {
    return (& $script:curl -s -o NUL -w "%{http_code}" $url)
}

function Start-Tomcat([bool]$stripHopByHop) {
    $flag = if ($stripHopByHop) { "true" } else { "false" }
    $script:tc = Start-Process -FilePath $script:java -ArgumentList @(
        "-DstripHopByHop=$flag", "-Dport=4003", "-cp", $script:cp, "EmbeddedProxy"
    ) -PassThru -NoNewWindow `
      -RedirectStandardOutput (New-TempLog "tomcat-out") `
      -RedirectStandardError  (New-TempLog "tomcat-err")
    if (-not (Wait-Port 4003 "/sse")) { throw "tomcat failed to start" }
}

try {
    $tomcatVersion = "9.0.118"
    if (-not (Test-Path "lib")) { New-Item -ItemType Directory -Path "lib" | Out-Null }
    if (-not (Get-ChildItem -Path "lib" -Filter "tomcat-embed-core-*.jar" -ErrorAction SilentlyContinue)) {
        Write-Host "==> downloading embedded Tomcat $tomcatVersion"
        Invoke-WebRequest -Uri "https://repo1.maven.org/maven2/org/apache/tomcat/embed/tomcat-embed-core/$tomcatVersion/tomcat-embed-core-$tomcatVersion.jar" `
            -OutFile "lib/tomcat-embed-core-$tomcatVersion.jar"
        Invoke-WebRequest -Uri "https://repo1.maven.org/maven2/org/apache/tomcat/tomcat-annotations-api/$tomcatVersion/tomcat-annotations-api-$tomcatVersion.jar" `
            -OutFile "lib/tomcat-annotations-api-$tomcatVersion.jar"
    }

    Write-Host "==> compiling servlet + Tomcat bootstrap"
    if (-not (Test-Path "out")) { New-Item -ItemType Directory -Path "out" | Out-Null }
    & $javac -cp "lib/*" -d out AIAssistantProxyServlet.java EmbeddedProxy.java
    if ($LASTEXITCODE -ne 0) { throw "compile failed" }

    Write-Host "==> starting Uvicorn :4000"
    $script:uv = Start-Process -FilePath $py -ArgumentList @(
        "-m","uvicorn","app:app","--app-dir",".","--host","127.0.0.1","--port","4000","--log-level","warning"
    ) -PassThru -NoNewWindow `
      -RedirectStandardOutput (New-TempLog "uvicorn-out") `
      -RedirectStandardError  (New-TempLog "uvicorn-err")
    if (-not (Wait-Port 4000 "/plain")) { throw "uvicorn failed to start" }

    Write-Host "==> starting NGINX :4088"
    if (Test-Path $err) { Clear-Content $err } else { New-Item -ItemType File -Path $err -Force | Out-Null }
    Start-Process powershell -ArgumentList @("-NoProfile","-File",$runNginx,"start") -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 1

    Write-Host ""
    Write-Host "################ PHASE 1 - FAULTY servlet (stripHopByHop=false) ################"
    Start-Tomcat $false
    Write-Host ("  servlet direct :4003   Transfer-Encoding count = {0}   (expect 2)" -f (Count-TransferEncoding "http://127.0.0.1:4003/sse"))
    $s1 = Http-Status "http://127.0.0.1:4088/sse"
    Write-Host ("  via NGINX :4088        HTTP {0}                          (expect 502)" -f $s1)
    $logLine = (Get-Content $err -ErrorAction SilentlyContinue |
        Select-String "duplicate header line" | Select-Object -Last 1).Line
    if ($logLine) { $logLine = $logLine -replace '^[0-9/ :]*','' }
    Write-Host ("  nginx error.log      : {0}" -f $(if ($logLine) { $logLine } else { "<no match>" }))
    Stop-Proc $script:tc; $script:tc = $null
    Start-Sleep -Seconds 1

    Write-Host ""
    Write-Host "################ PHASE 2 - FIXED servlet (stripHopByHop=true) ################"
    Start-Tomcat $true
    Write-Host ("  servlet direct :4003   Transfer-Encoding count = {0}   (expect 1)" -f (Count-TransferEncoding "http://127.0.0.1:4003/sse"))
    $s2 = Http-Status "http://127.0.0.1:4088/sse"
    Write-Host ("  via NGINX :4088        HTTP {0}                          (expect 200)" -f $s2)
    Write-Host "  stream via NGINX:"
    $stream = & $curl -s -N --max-time 3 "http://127.0.0.1:4088/sse"
    $stream -split "`r?`n" | Select-Object -First 6 | ForEach-Object { Write-Host ("      {0}" -f $_) }

    Write-Host ""
    Write-Host "============================= RESULT ============================="
    if ($s1 -eq "502" -and $s2 -eq "200") {
        Write-Host "PASS  faulty -> 502 (duplicate Transfer-Encoding) ; fixed -> 200 (single TE, SSE streams)"
    } else {
        Write-Host ("CHECK phase1(nginx)={0}  phase2(nginx)={1}" -f $s1, $s2)
    }
    Write-Host "=================================================================="
}
finally {
    Stop-Proc $script:tc
    Stop-Proc $script:uv
    if (Test-Path $runNginx) { & powershell -NoProfile -File $runNginx stop 2>$null | Out-Null }
}
