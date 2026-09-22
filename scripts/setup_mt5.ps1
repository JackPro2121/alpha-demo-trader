# MT5 setup v8: portable install + login pre-seed + known MCP key seed + discovery.
# Fresh terminals may generate no GUI-readable key until Generate is clicked.
# We pre-seed assistant.ini with a plaintext base64url ApiKey (GUI format) so the
# server can load it on first start; find_mcp_key.py probes seed + memory + config.

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

Write-Host "[3] writing login.ini + seed assistant.ini (known plaintext key)..."
$cfgDir = Join-Path $dir "Config"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
@"
[Common]
Login=$login
Password=$pass
Server=$server
"@ | Set-Content -Path (Join-Path $cfgDir "alpha_login.ini") -Encoding ASCII

# GUI-format base64url key (42 chars) — not hex. Server may load plaintext ApiKey
# on first start; if it regenerates/obfuscates, find_mcp_key still scans memory.
$seed = -join ((1..42) | ForEach-Object {
    $n = Get-Random -Maximum 64
    if ($n -lt 10) { [string]$n }
    elseif ($n -lt 36) { [char](55 + $n) }          # A-V-ish; force mixed
    elseif ($n -lt 62) { [char](61 + $n) }          # a-z-ish
    else { @('-','_')[$n - 62] }
})
# ensure charset is base64url and mixed case
$seed = [regex]::Replace($seed, '[^A-Za-z0-9_-]', 'x')
$bytes = New-Object byte[] 31
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$seed = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
if ($seed.Length -lt 40 -or $seed.Length -gt 44) { throw "seed key bad length $($seed.Length)" }

$asst = Join-Path $cfgDir "assistant.ini"
$ini = @"
[MCP.MetaTrader]
Enable=1
Endpoint=http://127.0.0.1:22346/mcp
ApiKey=$seed
"@
Set-Content -Path $asst -Value $ini -Encoding Unicode
Write-Host "seeded assistant.ini Enable=1 + plaintext ApiKey (len $($seed.Length), not printed)"

Write-Host "[4] launching terminal /portable /config (auto-login + MCP)..."
$loginIni = Join-Path $cfgDir "alpha_login.ini"
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"

$finder = Join-Path $repoRoot "scripts\find_mcp_key.py"
if (-not (Test-Path $finder)) { throw "find_mcp_key.py missing at $finder" }

function Invoke-KeyFind([string]$label) {
    Write-Host "$label discovering MCP key (seed + memory + config)..."
    $out = & python $finder --url "http://127.0.0.1:22346/mcp" --wait 150 --rescan 6 --seed-key $seed 2>&1
    $exit = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }
    if ($exit -ne 0) { return $null }
    $k = (@($out) | Where-Object { $_ -match '^[A-Za-z0-9_-]{40,64}$' -and $_ -ne '' } | Select-Object -Last 1)
    return $k
}

$key = Invoke-KeyFind "[5]"

if (-not $key) {
    Write-Host "[6] restart terminal (server reloads on-disk key) + retry..."
    Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
    # re-seed in case MT5 rewrote/obfuscated the ApiKey
    Set-Content -Path $asst -Value $ini -Encoding Unicode
    Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"
    $key = Invoke-KeyFind "[7]"
}

if (-not $key) {
    # dump config state for artifacts (lengths only)
    if (Test-Path $asst) {
        $txt = Get-Content $asst -Raw -ErrorAction SilentlyContinue
        if ($txt -match '(?im)ApiKey\s*=\s*(\S+)') {
            Write-Host ("assistant.ini ApiKey present len={0} hex_like={1}" -f $Matches[1].Length, ($Matches[1] -match '^[0-9a-fA-F]+$'))
        } else {
            Write-Host "assistant.ini ApiKey absent after runs"
        }
    }
    Write-Host "MCP_PORT_PROBE: LISTENING but auth unresolved"
    Write-Host "setup complete with WARNINGS -- watcher will run analysis-only"
    exit 0
}

"MCP_TOKEN=$key" | Add-Content -Path $env:GITHUB_ENV
Write-Host "MCP_PORT_PROBE: ALIVE+AUTH"
Write-Host "MCP_TOKEN exported (not printed)"
Write-Host "setup v8 complete"
