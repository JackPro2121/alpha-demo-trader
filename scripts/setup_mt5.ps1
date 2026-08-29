# MT5 setup v5: PORTABLE mode + login pre-seed + MCP key discovery.
# The terminal's MCP server uses a key MT5 generates itself (assistant.ini is
# MT5's OUTPUT, not input) — so after launch we read back the ApiKey MT5
# actually persists and hand that to the watcher step via GITHUB_ENV.

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

Write-Host "[3] writing login.ini + seed assistant.ini (portable config dir)..."
$cfgDir = Join-Path $dir "Config"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
@"
[Common]
Login=$login
Password=$pass
Server=$server
"@ | Set-Content -Path (Join-Path $cfgDir "alpha_login.ini") -Encoding ASCII

# Seed an assistant.ini the way a working terminal writes it (Enable=, Endpoint=,
# 64-hex key, UTF-16LE). If MT5 honors it, the key below IS the server key. If
# MT5 regenerates its own, step [5] discovers that and re-exports.
$key = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
$asst = Join-Path $cfgDir "assistant.ini"
$ini = "[MCP.MetaTrader]`r`nEnable=1`r`nEndpoint=http://127.0.0.1:22346/mcp`r`nApiKey=$key`r`n"
Set-Content -Path $asst -Value $ini -Encoding Unicode
"MCP_TOKEN=$key" | Add-Content -Path $env:GITHUB_ENV
Write-Host "seed written: $asst (ApiKey len $($key.Length), not printed)"

Write-Host "[4] launching terminal /portable /config (auto-login + MCP)..."
Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"

Write-Host "[5] discovering the MCP key the terminal actually uses..."
# Scan candidate assistant.ini locations; if MT5 rewrote the seed with its own
# key, re-export that. Never echo the key itself.
$ourKey = $key
$probeKey = $key
$ourFile = $asst
foreach ($i in 1..24) {
    Start-Sleep -Seconds 5
    $candidates = @($ourFile)
    $candidates += Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Recurse -Filter assistant.ini `
        -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    foreach ($f in $candidates) {
        if (-not (Test-Path $f)) { continue }
        if ($f -eq $ourFile -and (Get-Item $f).LastWriteTimeUtc -lt (Get-Date).AddMinutes(-2)) { continue }
        $txt = Get-Content $f -Raw -ErrorAction SilentlyContinue
        if ($txt -match '(?im)^\s*ApiKey\s*=\s*([0-9a-f]{32,128})\s*$') {
            $found = $Matches[1]
            if ($found -ne $ourKey) {
                Write-Host ("  MT5 rewrote {0} with its own key (len {1}) -- using it" -f $f, $found.Length)
                $probeKey = $found
            }
            else {
                Write-Host ("  key intact in {0} -- MT5 honored our seed" -f $f)
            }
            break
        }
    }
    if ($probeKey -ne $key) { break }
}
if ($probeKey -ne $key) {
    "MCP_TOKEN=$probeKey" | Add-Content -Path $env:GITHUB_ENV
    Write-Host "MCP_TOKEN re-exported with MT5's key"
}

Write-Host "[6] probing MCP server on 127.0.0.1:22346..."
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
$alive = $false
$authOk = $false
$seenStatus = @()
foreach ($i in 1..12) {
    Start-Sleep -Seconds 10
    try {
        $hdrs = @{ Accept = "application/json, text/event-stream" }
        if ($probeKey) { $hdrs.Authorization = "Bearer $probeKey" }
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:22346/mcp" -Method Post `
            -Headers $hdrs -ContentType "application/json" -Body $body -TimeoutSec 5 -SkipHttpErrorCheck
        $seenStatus += $r.StatusCode
        Write-Host ("  try {0}: HTTP {1}" -f $i, $r.StatusCode)
        if ($r.StatusCode -eq 200) { $alive = $true; $authOk = $true; break }
        if ($r.StatusCode -eq 401) {
            Write-Host "  server up but key rejected"
        }
    } catch {
        Write-Host ("  try {0}: {1}" -f $i, $_.Exception.Message)
    }
}
if ($alive) { Write-Host "MCP_PORT_PROBE: ALIVE+AUTH" }
elseif ($seenStatus.Count -gt 0) {
    Write-Host ("MCP_PORT_PROBE: LISTENING (statuses: {0}) but auth unresolved" -f (($seenStatus | Select-Object -Unique) -join ','))
    Write-Host "setup complete with WARNINGS -- watcher will run analysis-only"
}
else {
    Write-Host "MCP_PORT_PROBE: DEAD"
    Get-Process terminal64 -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("terminal process running: PID " + $_.Id)
    }
    throw "MCP server did not come up (see probe lines above)"
}
Write-Host "setup v5 complete"
