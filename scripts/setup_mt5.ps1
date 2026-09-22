# MT5 setup v7: portable install + login pre-seed + runtime MCP key discovery.
# Fresh installs regenerate the MCP bearer key; assistant.ini only holds an
# obfuscated hex the server rejects. The live key sits in terminal64 memory —
# find_mcp_key.py scans + probes until HTTP 200, then we export MCP_TOKEN.

$ErrorActionPreference = "Stop"
$setup = "$env:TEMP\mt5setup.exe"
$login = $env:MT5_LOGIN
$pass = $env:MT5_PASSWORD
$server = $env:MT5_SERVER
$repoRoot = Split-Path -Parent $PSScriptRoot

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

Write-Host "[3] writing login.ini (portable config dir)..."
$cfgDir = Join-Path $dir "Config"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
@"
[Common]
Login=$login
Password=$pass
Server=$server
"@ | Set-Content -Path (Join-Path $cfgDir "alpha_login.ini") -Encoding ASCII

# Enable MCP only — do NOT invent an ApiKey. Fresh terminals regenerate their
# own key; a fake hex here was the old 401. find_mcp_key.py reads the live one.
$asst = Join-Path $cfgDir "assistant.ini"
$ini = "[MCP.MetaTrader]`r`nEnable=1`r`nEndpoint=http://127.0.0.1:22346/mcp`r`n"
Set-Content -Path $asst -Value $ini -Encoding Unicode
Write-Host "seeded assistant.ini Enable=1 (no ApiKey)"

Write-Host "[4] launching terminal /portable /config (auto-login + MCP)..."
$loginIni = Join-Path $cfgDir "alpha_login.ini"
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"

$finder = Join-Path $repoRoot "scripts\find_mcp_key.py"
if (-not (Test-Path $finder)) { throw "find_mcp_key.py missing at $finder" }

Write-Host "[5] discovering MCP key from terminal memory + probing auth..."
$key = $null
# Pass 1: wait up to 3 minutes for port + 200
$out = & python $finder --url "http://127.0.0.1:22346/mcp" --wait 180 --rescan 6 2>&1
$exit = $LASTEXITCODE
$out | ForEach-Object { Write-Host "  $_" }
if ($exit -eq 0) {
    $key = (@($out) | Where-Object { $_ -match '^[A-Za-z0-9_-]{40,44}$' } | Select-Object -Last 1)
}

if (-not $key) {
    Write-Host "[6] first pass failed — restarting terminal and retrying discovery..."
    Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
    Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"
    $out = & python $finder --url "http://127.0.0.1:22346/mcp" --wait 180 --rescan 6 2>&1
    $exit = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }
    if ($exit -eq 0) {
        $key = (@($out) | Where-Object { $_ -match '^[A-Za-z0-9_-]{40,44}$' } | Select-Object -Last 1)
    }
}

if (-not $key) {
    Write-Host "MCP_PORT_PROBE: LISTENING but auth unresolved"
    Write-Host "setup complete with WARNINGS -- watcher will run analysis-only"
    exit 0
}

"MCP_TOKEN=$key" | Add-Content -Path $env:GITHUB_ENV
Write-Host "MCP_PORT_PROBE: ALIVE+AUTH"
Write-Host "MCP_TOKEN exported from live terminal key (not printed)"
Write-Host "setup v7 complete"
