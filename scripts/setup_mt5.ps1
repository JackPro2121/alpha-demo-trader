# MT5 setup v4: PORTABLE mode (all data inside install dir -> deterministic
# paths) + login/MCP pre-seed + port probe. No APPDATA guessing.

$ErrorActionPreference = "Stop"
$setup = "$env:TEMP\mt5setup.exe"
$login = $env:MT5_LOGIN
$pass = $env:MT5_PASSWORD
$server = $env:MT5_SERVER

if (-not $login -or -not $pass -or -not $server) { throw "MT5_LOGIN/MT5_PASSWORD/MT5_SERVER secrets missing" }

Write-Host "[1] downloading MT5 setup..."
if (-not (Test-Path $setup) -or (Get-Item $setup).Length -lt 1MB) {
    $urls = @(
        "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe",
        "https://download.mql5.com/cdn/web/exness.technologies.ltd/mt5/mt5setup.exe"
    )
    $ok = $false
    foreach ($attempt in 1..3) {
        foreach ($u in $urls) {
            Write-Host ("  attempt {0}: {1}" -f $attempt, $u)
            curl.exe -sSL --retry 2 --connect-timeout 30 $u -o $setup
            if ($LASTEXITCODE -eq 0 -and (Test-Path $setup) -and (Get-Item $setup).Length -gt 1MB) {
                $ok = $true; break
            }
            Write-Host "  download failed (exit $LASTEXITCODE), trying next source..."
        }
        if ($ok) { break }
        Start-Sleep -Seconds 15
    }
    if (-not $ok) { throw "MT5 setup download failed from all mirrors after 3 attempts" }
}
Write-Host ("  downloaded: {0:N1} MB" -f ((Get-Item $setup).Length / 1MB))
Write-Host "[2] installing /auto..."
Start-Process -FilePath $setup -ArgumentList "/auto" -Wait

$dir = "$env:ProgramFiles\MetaTrader 5"
$term = Join-Path $dir "terminal64.exe"
if (-not (Test-Path $term)) {
    $term = Get-ChildItem "$env:ProgramFiles" -Recurse -Filter terminal64.exe `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    $dir = Split-Path $term
}
if (-not (Test-Path $term)) { throw "terminal64.exe not found" }
Write-Host "terminal: $term"

Write-Host "[3] writing login.ini + assistant.ini (portable config dir)..."
$cfgDir = Join-Path $dir "Config"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
@"
[Common]
Login=$login
Password=$pass
Server=$server
"@ | Set-Content -Path (Join-Path $cfgDir "alpha_login.ini") -Encoding ASCII

# MT5 expects a 64-hex ApiKey (the format MT5 itself generates — verified
# against a working terminal's assistant.ini). Generate fresh per run and
# hand it to the watcher step via GITHUB_ENV so client and server never drift.
if ($env:MCP_KEY_OVERRIDE) { $key = $env:MCP_KEY_OVERRIDE }
else {
    $key = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
}
$asst = Join-Path $cfgDir "assistant.ini"
# Field names + UTF-16LE encoding copied from a working terminal's config;
# ASCII + Enabled= was silently ignored by the terminal (MCP 401s).
$ini = "[MCP.MetaTrader]`r`nEnable=1`r`nEndpoint=http://127.0.0.1:22346/mcp`r`nApiKey=$key`r`n"
Set-Content -Path $asst -Value $ini -Encoding Unicode
"MCP_TOKEN=$key" | Add-Content -Path $env:GITHUB_ENV
Write-Host "config written: $asst (ApiKey len $($key.Length), not printed)"

Write-Host "[4] launching terminal /portable /config (auto-login + MCP)..."
$loginIni = Join-Path $cfgDir "alpha_login.ini"
Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"

Write-Host "[5] waiting for MCP server (authenticated probe)..."
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
$alive = $false
foreach ($i in 1..12) {
    Start-Sleep -Seconds 10
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:22346/mcp" -Method Post `
            -Headers @{Authorization = "Bearer $key"; Accept = "application/json, text/event-stream"} `
            -ContentType "application/json" -Body $body -TimeoutSec 5 -SkipHttpErrorCheck
        Write-Host ("  try {0}: HTTP {1}" -f $i, $r.StatusCode)
        if ($r.StatusCode -eq 200) { $alive = $true; break }
        if ($r.StatusCode -eq 401) { Write-Host "  server up but key rejected -- assistant.ini not picked up" }
    } catch {
        Write-Host ("  try {0}: {1}" -f $i, $_.Exception.Message)
    }
}
if ($alive) { Write-Host "MCP_PORT_PROBE: ALIVE+AUTH" }
else {
    Write-Host "MCP_PORT_PROBE: DEAD"
    Get-Process terminal64 -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("terminal process running: PID " + $_.Id)
    }
    throw "MCP server did not come up (see probe lines above)"
}
Write-Host "setup v4 complete -- MCP ALIVE+AUTH"
