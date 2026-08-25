# MT5 setup v3: install -> pre-seed login + MCP config -> relaunch.
# Goal: terminal comes up AUTO-LOGGED-IN with its MCP HTTP server enabled
# using OUR key, so the proven MCPConnector path works on headless runners
# (the MetaTrader5 package's named-pipe IPC is broken: -10005 everywhere).

$ErrorActionPreference = "Stop"
$setup = "$env:TEMP\mt5setup.exe"
$url = "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
$key = $env:MT5_MCP_TOKEN
$login = $env:MT5_LOGIN
$pass = $env:MT5_PASSWORD
$server = $env:MT5_SERVER

if (-not $key) { throw "MT5_MCP_TOKEN secret missing" }

Write-Host "[1] downloading MT5 setup..."
if (-not (Test-Path $setup) -or (Get-Item $setup).Length -lt 1MB) {
    curl.exe -sSL $url -o $setup
}
Write-Host "[2] installing /auto..."
Start-Process -FilePath $setup -ArgumentList "/auto" -Wait

$term = @("$env:ProgramFiles\MetaTrader 5\terminal64.exe",
          "${env:ProgramFiles(x86)}\MetaTrader 5\terminal64.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $term) {
    $term = Get-ChildItem "$env:ProgramFiles" -Recurse -Filter terminal64.exe `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $term) { throw "terminal64.exe not found" }
Write-Host "terminal: $term"

Write-Host "[3] first launch (generates data folder)..."
Start-Process -FilePath $term
Start-Sleep -Seconds 30
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 5

Write-Host "[4] locating data folder..."
$cfgDir = Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Directory |
    ForEach-Object { Join-Path $_.FullName "config" } |
    Where-Object { Test-Path $_ } |
    Sort-Object (Get-Item $_).LastWriteTime -Descending |
    Select-Object -First 1
if (-not $cfgDir) { throw "terminal config dir not found" }
Write-Host "config dir: $cfgDir"

Write-Host "[5] writing assistant.ini (MCP enable + our key)..."
$asst = Join-Path $cfgDir "assistant.ini"
$ini = @()
if (Test-Path $asst) { $ini = Get-Content $asst }
$hasMt = ($ini | Select-String -SimpleMatch "[MCP.MetaTrader]").Count -gt 0
if (-not $hasMt) { $ini += "[MCP.MetaTrader]" }
$new = @(); $inMt = $false; $wroteKey = $false; $wroteEn = $false
foreach ($l in $ini) {
    if ($l -match '^\[(.+)\]') {
        if ($inMt) {
            if (-not $wroteKey) { $new += "ApiKey=$key"; $wroteKey = $true }
            if (-not $wroteEn)  { $new += "Enabled=1";   $wroteEn = $true }
        }
        $inMt = ($Matches[1] -eq "MCP.MetaTrader")
        $new += $l
        continue
    }
    if ($inMt -and $l -match '^ApiKey\s*=') { $new += "ApiKey=$key"; $wroteKey = $true; continue }
    if ($inMt -and $l -match '^Enabled\s*=') { $new += "Enabled=1"; $wroteEn = $true; continue }
    if ($inMt -and $l -match '^(Port|Address)\s*=') { continue }
    $new += $l
}
if ($inMt) {
    if (-not $wroteKey) { $new += "ApiKey=$key"; $wroteKey = $true }
    if (-not $wroteEn)  { $new += "Enabled=1";   $wroteEn = $true }
}
Set-Content -Path $asst -Value $new -Encoding ASCII
Write-Host "assistant.ini written (key len $($key.Length))"

Write-Host "[6] writing login.ini (auto-login)..."
$loginIni = Join-Path $cfgDir "alpha_login.ini"
@"
[Common]
Login=$login
Password=$pass
Server=$server
"@ | Set-Content -Path $loginIni -Encoding ASCII

Write-Host "[7] launching terminal with /config (auto-login)..."
Start-Process -FilePath $term -ArgumentList "/config:$loginIni"
Start-Sleep -Seconds 45

Write-Host "[8] MCP port probe..."
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:22346/mcp" -Method Get `
        -Headers @{Authorization = "Bearer $key"} -TimeoutSec 10 -SkipHttpErrorCheck
    Write-Host "MCP_PORT_PROBE: HTTP $($r.StatusCode) (401/405/400 = SERVER ALIVE)"
} catch {
    Write-Host "MCP_PORT_PROBE: DEAD -> $($_.Exception.Message)"
}
Write-Host "setup v3 complete"
