<#
.SYNOPSIS
  One self-contained Windows script that:
    1. runs a RAW-SOCKET "duplicating proxy" in front of any target URL,
    2. generates an nginx config and turns nginx on (showing its logs/failures),
    3. proves the duplicate `Transfer-Encoding` (or any header) reaches nginx,
       and that nginx returns 502 in the FAULTY case / 200 in the FIXED case.

  Why this reproduces it when hand-rolled scripts don't:
    * The proxy writes the duplicate header BYTES LITERALLY (no servlet/runtime
      that might de-dupe), so the FAULTY case ALWAYS emits two header lines.
    * It sends the RESPONSE HEADERS to nginx *before* streaming the body, so
      nginx rejects on the headers immediately (502) instead of timing out.
    * It needs no backend at all (-NoUpstream) and even falls back to a synthetic
      response if the target is unreachable -- so the duplicate ALWAYS shows.

.EXAMPLE
  # no backend needed -- just prove the duplicate + 502:
  powershell -ExecutionPolicy Bypass -File dup-header-lab.ps1 -NoUpstream -NonInteractive

.EXAMPLE
  # proxy in front of a real endpoint, faulty (reproduce) then fixed (cure):
  powershell -ExecutionPolicy Bypass -File dup-header-lab.ps1 -TargetUrl http://127.0.0.1:4000/sse
  powershell -ExecutionPolicy Bypass -File dup-header-lab.ps1 -TargetUrl http://127.0.0.1:4000/sse -Mode fixed

.EXAMPLE
  # target requires Basic auth:
  powershell -ExecutionPolicy Bypass -File dup-header-lab.ps1 -TargetUrl https://host/api/stream -Username alice -Password s3cret
#>
[CmdletBinding()]
param(
    [string]$TargetUrl,                                   # the real backend the proxy forwards to (URL #2)
    [int]$ProxyPort = 4001,                               # where the duplicating proxy listens (URL #1)
    [int]$NginxPort = 4088,                               # nginx front door
    [ValidateSet('faulty','fixed')][string]$Mode = 'faulty',
    [ValidateSet('GET','POST')][string]$Method = 'GET',
    [string]$Username,                                    # optional Basic auth -> sent to the TARGET
    [string]$Password,
    [string]$DuplicateHeader = 'Transfer-Encoding',       # which header to duplicate in faulty mode
    [string]$NginxDir,                                    # default: <scriptdir>\nginx-1.31.1
    [switch]$NoUpstream,                                  # serve a synthetic SSE response (no backend)
    [switch]$NonInteractive,                              # skip prompts and keep-alive wait
    [switch]$AsProxy                                      # INTERNAL: run only the proxy listener
)

# NOTE: 'Continue' (not 'Stop') on purpose: native nginx.exe writes normal output to
# stderr, which under 'Stop' would raise NativeCommandError. Our own error handling uses
# try/catch around .NET calls + explicit `throw`, which terminate regardless of this setting.
$ErrorActionPreference = 'Continue'
$enc = [System.Text.Encoding]::GetEncoding(28591)         # ISO-8859-1 (1 byte per char) for header bytes

# =====================================================================================
#  RAW-SOCKET PROXY  (shared by parent + the -AsProxy child)
# =====================================================================================
function Read-HttpLine([System.IO.Stream]$s) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    $got = $false
    while ($true) {
        $b = $s.ReadByte()
        if ($b -lt 0) { if (-not $got) { return $null } else { break } }
        $got = $true
        if ($b -eq 10) {                                  # \n  -> end of line
            if ($bytes.Count -gt 0 -and $bytes[$bytes.Count-1] -eq 13) { $bytes.RemoveAt($bytes.Count-1) }
            break
        }
        $bytes.Add([byte]$b)
    }
    return $enc.GetString($bytes.ToArray())
}

function Read-Exact([System.IO.Stream]$s, [int]$n) {
    $buf = New-Object byte[] $n
    $off = 0
    while ($off -lt $n) {
        $r = $s.Read($buf, $off, $n - $off)
        if ($r -le 0) { throw "EOF reading body ($off/$n)" }
        $off += $r
    }
    return $buf
}

function Write-Bytes([System.IO.Stream]$out, [byte[]]$b) { $out.Write($b, 0, $b.Length) }

function Write-Chunk([System.IO.Stream]$out, [byte[]]$data) {
    Write-Bytes $out ([System.Text.Encoding]::ASCII.GetBytes(('{0:x}' -f $data.Length) + "`r`n"))
    Write-Bytes $out $data
    Write-Bytes $out ([System.Text.Encoding]::ASCII.GetBytes("`r`n"))
    $out.Flush()
}

function Write-RespHeaders([System.IO.Stream]$out, [int]$status, [string]$reason, $endToEnd, [string]$dupVal) {
    $s = "HTTP/1.1 $status $reason`r`n"
    foreach ($h in $endToEnd) { $s += "$($h.Name): $($h.Value)`r`n" }
    if ($DuplicateHeader.ToLower() -eq 'transfer-encoding') {
        if ($Mode -eq 'faulty') { $s += "transfer-encoding: chunked`r`n"; $s += "Transfer-Encoding: chunked`r`n" }
        else                    { $s += "Transfer-Encoding: chunked`r`n" }
    } else {
        $s += "Transfer-Encoding: chunked`r`n"            # framing stays valid
        if ($Mode -eq 'faulty') { $s += "$($DuplicateHeader): $dupVal`r`n"; $s += "$($DuplicateHeader): $dupVal`r`n" }
        else                    { $s += "$($DuplicateHeader): $dupVal`r`n" }
    }
    $s += "Connection: close`r`n`r`n"
    Write-Bytes $out $enc.GetBytes($s)
    $out.Flush()
}

function Write-SyntheticBody([System.IO.Stream]$out) {
    for ($i = 0; $i -lt 5; $i++) {
        try { Write-Chunk $out ([System.Text.Encoding]::UTF8.GetBytes("data: message $i`n`n")) } catch { break }
        Start-Sleep -Milliseconds 120
    }
    try { Write-Bytes $out ([System.Text.Encoding]::ASCII.GetBytes("0`r`n`r`n")); $out.Flush() } catch {}
}

function Relay-Body([System.IO.Stream]$in, [System.IO.Stream]$out, [string]$framing, [int]$clen) {
    if ($framing -eq 'chunked') {
        while ($true) {
            $line = Read-HttpLine $in
            if ($null -eq $line) { break }
            if ($line.Length -eq 0) { continue }
            $semi = $line.IndexOf(';'); if ($semi -ge 0) { $line = $line.Substring(0, $semi) }
            $size = [Convert]::ToInt32($line.Trim(), 16)
            if ($size -eq 0) { while ($true) { $t = Read-HttpLine $in; if ([string]::IsNullOrEmpty($t)) { break } }; break }
            $chunk = Read-Exact $in $size
            Read-Exact $in 2 | Out-Null                   # trailing CRLF
            Write-Chunk $out $chunk
        }
    } elseif ($framing -eq 'length') {
        $remaining = $clen
        while ($remaining -gt 0) {
            $take = [Math]::Min(8192, $remaining)
            Write-Chunk $out (Read-Exact $in $take)
            $remaining -= $take
        }
    } else {                                              # read until upstream closes
        $buf = New-Object byte[] 8192
        while ($true) { $r = $in.Read($buf, 0, 8192); if ($r -le 0) { break }; Write-Chunk $out ([byte[]]($buf[0..($r-1)])) }
    }
    Write-Bytes $out ([System.Text.Encoding]::ASCII.GetBytes("0`r`n`r`n"))
    $out.Flush()
}

function Handle-Client($client) {
    $ns = $client.GetStream(); $ns.ReadTimeout = 120000; $ns.WriteTimeout = 120000
    $reqLine = Read-HttpLine $ns
    if (-not $reqLine) { return }
    $method = ($reqLine -split ' ')[0]
    $ch = @{}
    while ($true) {
        $l = Read-HttpLine $ns
        if ([string]::IsNullOrEmpty($l)) { break }
        $i = $l.IndexOf(':'); if ($i -gt 0) { $ch[$l.Substring(0,$i).Trim().ToLower()] = $l.Substring($i+1).Trim() }
    }
    $reqBody = [byte[]]@()
    if ($ch.ContainsKey('content-length')) { $n = [int]$ch['content-length']; if ($n -gt 0) { $reqBody = Read-Exact $ns $n } }
    $accept = if ($ch.ContainsKey('accept')) { $ch['accept'] } else { 'text/event-stream' }

    # ---- synthetic (no backend) ----
    if ($NoUpstream) {
        Write-Host "[proxy] $method (synthetic) -> $(if($Mode -eq 'faulty'){'2'}else{'1'}) x '$DuplicateHeader'"
        $e2e = @(@{Name='Content-Type';Value='text/event-stream; charset=utf-8'}, @{Name='Cache-Control';Value='no-cache'})
        Write-RespHeaders $ns 200 'OK' $e2e 'synthetic'
        Write-SyntheticBody $ns
        return
    }

    # ---- real upstream ----
    $u = [System.Uri]$TargetUrl
    $tcp = $null; $us = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($u.Host, $u.Port)
        $raw = $tcp.GetStream()
        if ($u.Scheme -eq 'https') {
            $us = New-Object System.Net.Security.SslStream($raw, $false, ([System.Net.Security.RemoteCertificateValidationCallback]{ $true }))
            $us.AuthenticateAsClient($u.Host)
        } else { $us = $raw }
    } catch {
        Write-Host "[proxy] upstream connect FAILED: $($_.Exception.Message) -- serving synthetic so the duplicate still shows"
        $e2e = @(@{Name='Content-Type';Value='text/event-stream; charset=utf-8'})
        Write-RespHeaders $ns 200 'OK' $e2e 'synthetic'; Write-SyntheticBody $ns; return
    }

    $path = $u.PathAndQuery; if (-not $path) { $path = '/' }
    $sb = "$method $path HTTP/1.1`r`nHost: $($u.Host):$($u.Port)`r`nAccept: $accept`r`nAccept-Encoding: identity`r`nConnection: close`r`n"
    if ($script:AuthOn) { $sb += "Authorization: Basic $($script:AuthB64)`r`n" }
    if ($reqBody.Length -gt 0) {
        $ct = if ($ch.ContainsKey('content-type')) { $ch['content-type'] } else { 'application/octet-stream' }
        $sb += "Content-Type: $ct`r`nContent-Length: $($reqBody.Length)`r`n"
    }
    $sb += "`r`n"
    Write-Bytes $us $enc.GetBytes($sb)
    if ($reqBody.Length -gt 0) { Write-Bytes $us $reqBody }
    $us.Flush()

    $statusLine = Read-HttpLine $us
    if (-not $statusLine) { $tcp.Close(); return }
    $sp = $statusLine -split ' ', 3
    $ustatus = [int]$sp[1]; $ureason = if ($sp.Count -ge 3) { $sp[2] } else { 'OK' }
    $uheaders = @(); $framing = 'close'; $clen = -1
    while ($true) {
        $l = Read-HttpLine $us
        if ([string]::IsNullOrEmpty($l)) { break }
        $i = $l.IndexOf(':'); if ($i -lt 1) { continue }
        $nm = $l.Substring(0,$i).Trim(); $vl = $l.Substring($i+1).Trim()
        $uheaders += @{Name=$nm; Value=$vl}
        $ln = $nm.ToLower()
        if ($ln -eq 'transfer-encoding' -and $vl.ToLower().Contains('chunked')) { $framing = 'chunked' }
        if ($ln -eq 'content-length') { $framing = 'length'; $clen = [int]$vl }
    }
    Write-Host "[proxy] $method $path -> $TargetUrl : upstream=$ustatus framing=$framing auth=$($script:AuthOn) -> emitting $(if($Mode -eq 'faulty'){'2'}else{'1'}) x '$DuplicateHeader'"

    $skip = @('transfer-encoding','content-length','connection','keep-alive','proxy-authenticate','proxy-authorization','te','trailer','upgrade', $DuplicateHeader.ToLower())
    $e2e = $uheaders | Where-Object { $skip -notcontains $_.Name.ToLower() }
    $dupVal = 'chunked'
    if ($DuplicateHeader.ToLower() -ne 'transfer-encoding') {
        $m = $uheaders | Where-Object { $_.Name.ToLower() -eq $DuplicateHeader.ToLower() } | Select-Object -First 1
        $dupVal = if ($m) { $m.Value } else { 'duplicate-value' }
    }
    Write-RespHeaders $ns $ustatus $ureason $e2e $dupVal
    try { Relay-Body $us $ns $framing $clen } catch { Write-Host "[proxy] body relay stopped (nginx likely rejected headers): $($_.Exception.Message)" }
    $tcp.Close()
}

function Invoke-ProxyListener {
    $script:AuthOn = $false; $script:AuthB64 = ''
    if ($Username) { $script:AuthOn = $true; $script:AuthB64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($Username):$($Password)")) }
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $ProxyPort)
    $listener.Start()
    Write-Host "[proxy] listening 127.0.0.1:$ProxyPort  mode=$Mode  dupHeader=$DuplicateHeader  auth=$($script:AuthOn)  target=$(if($NoUpstream){'(synthetic)'}else{$TargetUrl})"
    while ($true) {
        $client = $null
        try { $client = $listener.AcceptTcpClient(); Handle-Client $client }
        catch { Write-Host "[proxy] handler error: $($_.Exception.Message)" }
        finally { if ($client) { try { $client.Close() } catch {} } }
    }
}

if ($AsProxy) { Invoke-ProxyListener; exit 0 }

# =====================================================================================
#  PARENT: interactive prompts -> start proxy -> configure+start nginx -> verify
# =====================================================================================
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function SayLine($c = 'DarkGray') { Say ('  ' + ('-' * 66)) $c }

# =====================================================================================
#  RELIABLE HEADER COUNTING  (uses curl -D tempfile so NO stdout interleaving)
# =====================================================================================
function Get-RawHeaders([string]$url, [string]$httpMethod = 'GET') {
    <#
    .SYNOPSIS
      Sends a request with curl.exe, captures response headers to a temp file,
      returns the raw header text (every line preserved, including duplicates).
      This avoids the PowerShell stdout-interleaving bug where -D - can lose or
      merge header lines when the response body is also streaming to stdout.
    #>
    $guid = [Guid]::NewGuid().ToString('N')
    $hdrFile = Join-Path ([IO.Path]::GetTempPath()) "duphdr-hdrs-$guid.txt"
    try {
        # -D file     : dump headers to file (NOT stdout) -- this is the KEY fix
        # -o NUL      : discard body
        # -s          : silent (no progress)
        # --max-time  : don't hang on streaming endpoints
        # --raw       : don't decode transfer-encoding (keeps header bytes literal)
        & $curl -s -X $httpMethod --raw -D $hdrFile -o NUL --max-time 10 $url 2>$null
        if (Test-Path $hdrFile) {
            return (Get-Content $hdrFile -Raw)
        }
        return ''
    } finally {
        Remove-Item $hdrFile -ErrorAction SilentlyContinue
    }
}

function Count-Header([string]$rawHeaders, [string]$headerName) {
    <#
    .SYNOPSIS
      Counts occurrences of a header name in raw header text.
      Case-insensitive, anchored to line start.
    #>
    if (-not $rawHeaders) { return 0 }
    $pattern = '(?im)^' + [regex]::Escape($headerName) + '\s*:'
    return ([regex]::Matches($rawHeaders, $pattern)).Count
}

function Get-HttpStatus([string]$url, [string]$httpMethod = 'GET') {
    return (& $curl -s -X $httpMethod -o NUL -w '%{http_code}' --max-time 10 $url 2>$null)
}

# =====================================================================================
#  INTERACTIVE PROMPTS
# =====================================================================================
if (-not $NonInteractive) {
    Say '' 'White'
    SayLine 'Cyan'
    Say '  DUPLICATE-HEADER LAB  (interactive mode)' 'Cyan'
    SayLine 'Cyan'
    Say ''
    Say '  This script starts a raw-socket proxy that injects duplicate'
    Say '  headers, points nginx at it, and verifies the result.'
    Say ''

    if (-not $NoUpstream -and -not $TargetUrl) {
        Say '  Enter the TARGET URL (the real backend to proxy to).' 'Yellow'
        Say '  Leave blank for built-in synthetic SSE (no backend needed).' 'DarkGray'
        $t = Read-Host '  Target URL'
        if ([string]::IsNullOrWhiteSpace($t)) { $NoUpstream = $true } else { $TargetUrl = $t }
    }
    if (-not $PSBoundParameters.ContainsKey('Mode')) {
        Say ''
        Say "  Mode: 'faulty' reproduces the duplicate header (expect 502)." 'Yellow'
        Say "         'fixed'  sends only one header (expect 200)." 'Yellow'
        $m = Read-Host '  Mode [faulty/fixed] (default: faulty)'
        if ($m -eq 'fixed') { $Mode = 'fixed' }
    }
    if (-not $PSBoundParameters.ContainsKey('Method')) {
        Say ''
        Say "  Method: 'GET' or 'POST' for the test requests." 'Yellow'
        $hm = Read-Host '  Method [GET/POST] (default: GET)'
        if ($hm -eq 'POST' -or $hm -eq 'post') { $Method = 'POST' }
    }
    if (-not $Username) {
        Say ''
        Say '  Optional: Basic-auth credentials sent to the TARGET.' 'Yellow'
        Say '  Leave blank if the target does not require auth.' 'DarkGray'
        $usr = Read-Host '  Username (blank = no auth)'
        if (-not [string]::IsNullOrWhiteSpace($usr)) {
            $Username = $usr
            $sec = Read-Host '  Password' -AsSecureString
            $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        }
    }
    Say ''
    Say '  Ports (press Enter to keep defaults):' 'Yellow'
    $pp = Read-Host "  Proxy listen port [$ProxyPort]"; if ($pp -match '^\d+$') { $ProxyPort = [int]$pp }
    $np = Read-Host "  NGINX listen port [$NginxPort]"; if ($np -match '^\d+$') { $NginxPort = [int]$np }
    Say ''
    Say '  Which header to duplicate in faulty mode:' 'Yellow'
    $dh = Read-Host "  Header name [$DuplicateHeader]"
    if (-not [string]::IsNullOrWhiteSpace($dh)) { $DuplicateHeader = $dh.Trim() }
}
if (-not $TargetUrl -and -not $NoUpstream) { $NoUpstream = $true }

# ---- locate nginx ----
if (-not $NginxDir) { $NginxDir = Join-Path $PSScriptRoot 'nginx-1.31.1' }
$nginxExe = Join-Path $NginxDir 'nginx.exe'
if (-not (Test-Path $nginxExe)) {
    $msg = "nginx.exe not found at $nginxExe -- Run scripts\setup.ps1 first, or pass -NginxDir."
    Say $msg 'Red'; exit 1
}
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if (-not $curl) { Say 'curl.exe not found in PATH.' 'Red'; exit 1 }

$logsDir = Join-Path $NginxDir 'logs'
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
$errLog  = Join-Path $logsDir 'duphdr-error.log'
$confPath = Join-Path $NginxDir 'conf\duphdr.conf'
$pidPath  = Join-Path $logsDir 'duphdr.pid'
$fwd = { param($p) ($p -replace '\\','/') }
$nginxConf = @"
worker_processes  1;
error_log  "$(& $fwd $errLog)"  info;
pid        "$(& $fwd $pidPath)";
events { worker_connections 256; }
http {
    access_log off;
    server {
        listen 127.0.0.1:$NginxPort;
        location / {
            proxy_pass http://127.0.0.1:$ProxyPort;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 1h;
        }
    }
}
"@
Set-Content -Path $confPath -Value $nginxConf -Encoding ascii

$reqPath = '/sse'
if (-not $NoUpstream) {
    try {
        $p = ([System.Uri]$TargetUrl).PathAndQuery
        if ($p) { $reqPath = $p }
    } catch {}
}
$guid1 = [Guid]::NewGuid().ToString('N')
$guid2 = [Guid]::NewGuid().ToString('N')
$proxyOut = Join-Path ([IO.Path]::GetTempPath()) "duphdr-proxy-$guid1.log"
$proxyErr = Join-Path ([IO.Path]::GetTempPath()) "duphdr-proxyerr-$guid2.log"
$script:proxyProc = $null

function Stop-All {
    if ($script:proxyProc -and -not $script:proxyProc.HasExited) { try { $script:proxyProc.Kill() } catch {} }
    try { & $nginxExe -p $NginxDir -c $confPath -s quit 2>$null | Out-Null } catch {}
}

try {
    Say ''
    SayLine 'Cyan'
    Say '  CONFIGURATION' 'Cyan'
    SayLine 'Cyan'
    $targetDisplay = if ($NoUpstream) { '(synthetic SSE -- no backend)' } else { $TargetUrl }
    $authDisplay = if ($Username) { "enabled (user '$Username') -> sent to target" } else { 'disabled' }
    Say "  mode        : $Mode" 'White'
    Say "  method      : $Method" 'White'
    Say "  target      : $targetDisplay" 'White'
    Say "  auth        : $authDisplay" 'White'
    Say "  proxy       : 127.0.0.1:$ProxyPort" 'White'
    Say "  nginx       : 127.0.0.1:$NginxPort" 'White'
    Say "  duplicating : $DuplicateHeader" 'White'
    SayLine 'Cyan'
    Say ''

    # ---- 0) kill any stale nginx on this config ----
    try { & $nginxExe -p $NginxDir -c $confPath -s quit 2>$null | Out-Null } catch {}
    Start-Sleep -Milliseconds 500

    # ---- 1) start the raw-socket proxy (this very script, re-invoked with -AsProxy) ----
    Say "  [1/4] Starting raw-socket proxy on :$ProxyPort ..." 'Cyan'
    $childArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-AsProxy',
                   '-ProxyPort',$ProxyPort,'-Mode',$Mode,'-DuplicateHeader',$DuplicateHeader,'-Method',$Method,'-NonInteractive')
    if ($NoUpstream) { $childArgs += '-NoUpstream' } else { $childArgs += @('-TargetUrl',$TargetUrl) }
    if ($Username)   { $childArgs += @('-Username',$Username,'-Password',$Password) }
    $script:proxyProc = Start-Process powershell -ArgumentList $childArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $proxyOut -RedirectStandardError $proxyErr
    $ok = $false
    for ($i=0; $i -lt 60; $i++) {
        & $curl -s -X $Method -o NUL "http://127.0.0.1:$ProxyPort$reqPath" 2>$null
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $ok) {
        Say "  [FAIL] Proxy FAILED to start on :$ProxyPort" 'Red'
        Say '    --- proxy stderr ---' 'Red'
        Get-Content $proxyErr -ErrorAction SilentlyContinue | ForEach-Object { Say "    $_" 'Red' }
        throw "proxy not listening on $ProxyPort"
    }
    Say "  [OK]  Proxy is up on :$ProxyPort" 'Green'

    # ---- 2) validate + start nginx ----
    Say ''
    Say "  [2/4] Validating + starting nginx on :$NginxPort ..." 'Cyan'
    $testOutput = & $nginxExe -p $NginxDir -c $confPath -t 2>&1
    $testOutput | ForEach-Object { Say "    nginx -t: $_" 'DarkGray' }
    $testFailed = $testOutput | Where-Object { $_ -match 'emerg|error|failed' }
    if ($testFailed) {
        Say '  [FAIL] nginx config validation FAILED:' 'Red'
        $testFailed | ForEach-Object { Say "    $_" 'Red' }
        throw 'nginx -t failed'
    }

    # clear error log before starting so we only capture this run
    if (Test-Path $errLog) { Clear-Content $errLog }
    Start-Process $nginxExe -ArgumentList @('-p',$NginxDir,'-c',$confPath) -WindowStyle Hidden | Out-Null
    $ok = $false
    for ($i=0; $i -lt 50; $i++) {
        & $curl -s -X $Method -o NUL "http://127.0.0.1:$NginxPort/" 2>$null
        if ($LASTEXITCODE -ne 7) { $ok = $true; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $ok) {
        Say "  [FAIL] nginx did NOT come up on :$NginxPort" 'Red'
        Say '    --- nginx error.log (last 20 lines) ---' 'Red'
        if (Test-Path $errLog) {
            Get-Content $errLog -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { Say "    $_" 'Red' }
        } else {
            Say '    (no error log found)' 'Red'
        }
        throw "nginx not listening on $NginxPort"
    }
    Say "  [OK]  nginx is up on :$NginxPort" 'Green'

    # ---- 3) send test requests + capture raw headers ----
    Say ''
    Say '  [3/4] Sending test requests, capturing raw headers ...' 'Cyan'
    Say ''

    # --- Direct to proxy (bypassing nginx) ---
    $directUrl  = "http://127.0.0.1:$ProxyPort$reqPath"
    $directHdrs = Get-RawHeaders $directUrl $Method
    $directCount = Count-Header $directHdrs $DuplicateHeader

    # --- Through nginx ---
    Start-Sleep -Milliseconds 500  # let nginx settle after its startup test request
    if (Test-Path $errLog) { Clear-Content $errLog }  # clear so we capture ONLY the real test
    $nginxUrl   = "http://127.0.0.1:$NginxPort$reqPath"
    $nginxHdrs  = Get-RawHeaders $nginxUrl $Method
    $nginxStatus = Get-HttpStatus $nginxUrl $Method
    $nginxCount  = Count-Header $nginxHdrs $DuplicateHeader

    # Read nginx error log for duplicate-header messages
    Start-Sleep -Milliseconds 300
    $dupLogLines = @()
    $allNginxErrors = @()
    if (Test-Path $errLog) {
        $allNginxErrors = @(Get-Content $errLog -ErrorAction SilentlyContinue)
        $dupLogLines = @($allNginxErrors | Select-String 'duplicate header line|Transfer-Encoding|Content-Length' | ForEach-Object { $_.Line })
    }

    # ---- 4) RESULTS ----
    Say ''
    Say '  [4/4] Results' 'Cyan'
    Say ''
    SayLine 'Cyan'
    Say '                          TEST  RESULTS' 'Cyan'
    SayLine 'Cyan'
    Say ''

    # -- Raw headers from direct proxy --
    Say "  [A] Raw headers from PROXY (direct :$ProxyPort)" 'Yellow'
    SayLine 'Yellow'
    if ($directHdrs) {
        $escapedHdr = [regex]::Escape($DuplicateHeader)
        $directHdrs -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object {
            $line = $_.Trim()
            $isTarget = $line -match "(?i)^${escapedHdr}\s*:"
            if ($isTarget) {
                Say "  >>> $line <<<" 'Magenta'
            } else {
                Say "      $line" 'DarkGray'
            }
        }
    } else {
        Say '      (no headers captured!)' 'Red'
    }
    SayLine 'Yellow'
    Say ''

    # -- Raw headers from nginx --
    Say "  [B] Raw headers from NGINX (:$NginxPort)" 'Yellow'
    SayLine 'Yellow'
    if ($nginxHdrs) {
        $nginxHdrs -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object {
            $line = $_.Trim()
            $isTarget = $line -match "(?i)^${escapedHdr}\s*:"
            $isStatus = $line -match '^HTTP/'
            if ($isTarget) {
                Say "  >>> $line <<<" 'Magenta'
            } elseif ($isStatus -and $line -match '502') {
                Say "      $line" 'Red'
            } elseif ($isStatus) {
                Say "      $line" 'Green'
            } else {
                Say "      $line" 'DarkGray'
            }
        }
    } else {
        Say '      (no headers captured -- nginx may have closed immediately)' 'Red'
    }
    SayLine 'Yellow'
    Say ''

    # -- Summary table --
    Say '  [C] Summary' 'Cyan'
    SayLine 'Cyan'
    $line1 = "  Direct proxy  :$ProxyPort   '$DuplicateHeader' count = $directCount   (faulty expects 2, fixed expects 1)"
    $line2 = "  Via NGINX     :$NginxPort   HTTP $nginxStatus            (faulty expects 502, fixed expects 200)"
    $line3 = "  Via NGINX           '$DuplicateHeader' count = $nginxCount"
    Say $line1 'White'
    Say $line2 'White'
    Say $line3 'White'
    SayLine 'Cyan'
    Say ''

    # -- Nginx error log --
    Say '  [D] NGINX error log' 'Yellow'
    SayLine 'Yellow'
    if ($dupLogLines.Count -gt 0) {
        foreach ($dl in $dupLogLines) {
            # strip timestamp for readability
            $cleaned = $dl -replace '^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} ',''
            Say "      $cleaned" 'Red'
        }
    } else {
        Say '      (no duplicate-header errors in nginx log)' 'DarkGray'
    }
    # also show any [emerg] or [crit] lines
    $otherErrors = @($allNginxErrors | Where-Object { $_ -match '\[(emerg|crit)\]' })
    if ($otherErrors.Count -gt 0) {
        Say ''
        Say '      Other critical nginx errors:' 'Red'
        $otherErrors | Select-Object -Last 5 | ForEach-Object {
            $cleaned = $_ -replace '^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} ',''
            Say "        $cleaned" 'Red'
        }
    }
    SayLine 'Yellow'
    Say ''

    # -- Proxy child process log --
    Say '  [E] Proxy log (last lines)' 'DarkCyan'
    SayLine 'DarkCyan'
    $proxyLines = @(Get-Content $proxyOut -ErrorAction SilentlyContinue | Select-Object -Last 8)
    if ($proxyLines.Count -gt 0) {
        $proxyLines | ForEach-Object { Say "      $_" 'DarkGray' }
    } else {
        Say '      (no proxy output captured)' 'DarkGray'
    }
    $proxyErrLines = @(Get-Content $proxyErr -ErrorAction SilentlyContinue | Select-Object -Last 5)
    if ($proxyErrLines.Count -gt 0) {
        Say '      --- stderr ---' 'Red'
        $proxyErrLines | ForEach-Object { Say "      $_" 'Red' }
    }
    SayLine 'DarkCyan'
    Say ''

    # -- PASS / FAIL verdict --
    $teLike = @('transfer-encoding','content-length') -contains $DuplicateHeader.ToLower()
    $pass = $false
    if ($Mode -eq 'faulty') {
        $pass = ($directCount -ge 2) -and ((-not $teLike) -or ($nginxStatus -eq '502'))
    } else {
        $pass = ($directCount -eq 1) -and ((-not $teLike) -or ($nginxStatus -eq '200'))
    }
    SayLine 'Cyan'
    if ($pass) {
        Say '  RESULT: PASS' 'Green'
    } else {
        $expectDirect = if ($Mode -eq 'faulty') { '>=2' } else { '1' }
        $expectStatus = if ($Mode -eq 'faulty') { '502' } else { '200' }
        Say "  RESULT: CHECK / FAIL  (direct=$directCount expect=$expectDirect  status=$nginxStatus expect=$expectStatus  mode=$Mode)" 'Yellow'
    }
    SayLine 'Cyan'
    Say ''
    Say '  Manual test commands:' 'DarkGray'
    Say "    curl -X $Method -i -N http://127.0.0.1:$NginxPort$reqPath" 'DarkGray'
    Say "    curl -X $Method -i -N http://127.0.0.1:$ProxyPort$reqPath" 'DarkGray'
    Say ''

    if (-not $NonInteractive) { Read-Host '  Services are running. Press Enter to stop nginx + proxy and exit' | Out-Null }
}
finally {
    Stop-All
    Say '  stopped nginx + proxy.' 'DarkGray'
}
