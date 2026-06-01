# Start the Java proxy.
# Usage:  powershell -File scripts\run-proxy.ps1 [naive|fixed]
#   naive -> :4001  (faulty, copies hop-by-hop Transfer-Encoding)
#   fixed -> :4002  (correct, strips hop-by-hop headers)
param([string]$Mode = "naive")
$root = Split-Path -Parent $PSScriptRoot
$java = (Get-Command java -ErrorAction SilentlyContinue).Source
if (-not $java) { Write-Error "java not found in PATH"; exit 1 }

switch ($Mode.ToLower()) {
    "naive" {
        Write-Host "[run-proxy] FAULTY (copies hop-by-hop Transfer-Encoding) -> :4001"
        & $java (Join-Path $root "java-proxy\NaiveProxy.java")
    }
    "fixed" {
        Write-Host "[run-proxy] FIXED (strips hop-by-hop headers) -> :4002"
        & $java (Join-Path $root "java-proxy\FixedProxy.java")
    }
    default {
        Write-Error "Usage: run-proxy.ps1 [naive|fixed]"
        exit 2
    }
}
