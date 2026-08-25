# Silent MetaTrader 5 install for GitHub Windows runners.
# Downloads the MetaQuotes CDN bootstrapper and installs /auto, then
# waits for terminal64.exe to exist. Credentials are NOT used here --
# the MetaTrader5 python package logs in at runtime (initialize(login=...)).

$ErrorActionPreference = "Stop"
$setup = "$env:TEMP\mt5setup.exe"
$url = "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

Write-Host "downloading MT5 setup..."
curl.exe -sSL $url -o $setup
if (-not (Test-Path $setup) -or (Get-Item $setup).Length -lt 1MB) {
    throw "MT5 setup download failed"
}

Write-Host "installing (silent /auto)..."
Start-Process -FilePath $setup -ArgumentList "/auto" -Wait

$paths = @(
    "$env:ProgramFiles\MetaTrader 5\terminal64.exe",
    "${env:ProgramFiles(x86)}\MetaTrader 5\terminal64.exe"
)
$term = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $term) {
    # /auto sometimes lands under a branded folder; search broadly
    $term = Get-ChildItem "$env:ProgramFiles" -Recurse -Filter terminal64.exe `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $term) { throw "terminal64.exe not found after install" }
Write-Host "terminal at: $term"

# first launch so the MetaTrader5 package can attach cleanly
Start-Process -FilePath $term
Start-Sleep -Seconds 20
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 5
Write-Host "MT5 terminal installed OK"
