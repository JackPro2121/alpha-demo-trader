# MT5 setup v9: install + enable MCP WITHOUT seeding ApiKey (Generate/default path).
# Seeding a plaintext ApiKey made MT5 rewrite assistant.ini to 168-hex (broken
# Generate-style key per MQL5 forum #515076 — default key works, Generate often 401s).
# Strategy: Enable=1 only, let MT5 create its default key, then discover via
# raw-hex-as-bearer + memory scan + deobfuscation. Fallback: alternate port.

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
        "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
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

Write-Host "[3] writing login.ini + assistant.ini Enable=1 (NO ApiKey seed)..."
$cfgDir = Join-Path $dir "Config"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
@"
[Common]
Login=$login
Password=$pass
Server=$server
"@ | Set-Content -Path (Join-Path $cfgDir "alpha_login.ini") -Encoding ASCII

# Enable MCP only — do NOT write ApiKey (seed forced MT5 into broken rewrite path).
# MetaTrader creates its default working key on first enable (forum: default works).
$asst = Join-Path $cfgDir "assistant.ini"
$ini = @"
[MCP.MetaTrader]
Enable=1
Endpoint=http://127.0.0.1:22346/mcp
"@
Set-Content -Path $asst -Value $ini -Encoding Unicode
Write-Host "seeded assistant.ini Enable=1 only (no ApiKey)"

# Always-stage assistant.ini (post-run) for artifact upload (lengths only in logs).
$artDir = Join-Path $env:RUNNER_TEMP "mt5-config"
New-Item -ItemType Directory -Force -Path $artDir | Out-Null

Write-Host "[4] launching terminal /portable /config (auto-login + MCP)..."
$loginIni = Join-Path $cfgDir "alpha_login.ini"
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"

$finder = Join-Path $repoRoot "scripts\find_mcp_key.py"
if (-not (Test-Path $finder)) { throw "find_mcp_key.py missing at $finder" }

function Invoke-KeyFind([string]$label, [string]$url) {
    Write-Host "$label discovering MCP key at $url (hex-as-bearer + memory + config)..."
    $out = & python $finder --url $url --wait 150 --rescan 6 2>&1
    $exit = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }
    if ($exit -ne 0) { return $null }
    $k = (@($out) | Where-Object { $_ -match '^[A-Za-z0-9_-]{40,64}$' -and $_ -ne '' } | Select-Object -Last 1)
    return $k
}

$key = Invoke-KeyFind "[5]" "http://127.0.0.1:22346/mcp"

# dump lengths for diagnosis + stage for artifact
function Save-ConfigDiag {
    if (Test-Path $asst) {
        Copy-Item $asst (Join-Path $artDir "assistant.ini") -Force -EA SilentlyContinue
        $txt = Get-Content $asst -Raw -EA SilentlyContinue
        if ($txt -match '(?im)ApiKey\s*=\s*(\S+)') {
            $v = $Matches[1]
            Write-Host ("assistant.ini ApiKey present len={0} hex_like={1}" -f $v.Length, ($v -match '^[0-9a-fA-F]+$'))
        } else {
            Write-Host "assistant.ini ApiKey ABSENT (MT5 did not write one)"
        }
        Write-Host ("assistant.ini bytes={0}" -f (Get-Item $asst).Length)
    } else {
        Write-Host "assistant.ini missing at $asst"
    }
    # portable config too
    $portCfg = Join-Path $dir "Config\assistant.ini"
    # also data-folder assistant (non-portable path)
    $roaming = Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Recurse -Filter assistant.ini -EA SilentlyContinue
    foreach ($f in $roaming) {
        Copy-Item $f.FullName (Join-Path $artDir ("assistant_" + $f.Directory.Name + ".ini")) -Force -EA SilentlyContinue
        $txt = Get-Content $f.FullName -Raw -EA SilentlyContinue
        if ($txt -match '(?im)ApiKey\s*=\s*(\S+)') {
            Write-Host ("roaming {0} ApiKey len={1}" -f $f.FullName, $Matches[1].Length)
        }
    }
    # stage terminal logs (tail)
    $logRoots = @("$env:APPDATA\MetaQuotes\Terminal", (Join-Path $dir "logs"))
    foreach ($lr in $logRoots) {
        if (Test-Path $lr) {
            Get-ChildItem $lr -Recurse -Filter *.log -EA SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 4 |
                ForEach-Object { Copy-Item $_.FullName (Join-Path $artDir $_.Name) -Force -EA SilentlyContinue }
        }
    }
}

Save-ConfigDiag

if (-not $key) {
    Write-Host "[6] restart terminal (reload on-disk default key) + retry..."
    Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
    Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"
    $key = Invoke-KeyFind "[7]" "http://127.0.0.1:22346/mcp"
    Save-ConfigDiag
}

# Forum fix: regenerate + change port (22344) when 22346 stays 401.
if (-not $key) {
    Write-Host "[8] rewrite Endpoint to :22344 + restart + retry..."
    Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    $ini2 = @"
[MCP.MetaTrader]
Enable=1
Endpoint=http://127.0.0.1:22344/mcp
"@
    Set-Content -Path $asst -Value $ini2 -Encoding Unicode
    Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"
    $key = Invoke-KeyFind "[9]" "http://127.0.0.1:22344/mcp"
    Save-ConfigDiag
    if ($key) {
        "MT5_MCP_URL=http://127.0.0.1:22344/mcp" | Add-Content -Path $env:GITHUB_ENV
        Write-Host "MCP url switched to 22344"
    }
}

if (-not $key) {
    Write-Host "MCP_PORT_PROBE: LISTENING but auth unresolved"
    Write-Host "setup complete with WARNINGS -- watcher will run analysis-only"
    exit 0
}

"MCP_TOKEN=$key" | Add-Content -Path $env:GITHUB_ENV
Write-Host "MCP_PORT_PROBE: ALIVE+AUTH"
Write-Host "MCP_TOKEN exported (not printed)"
Write-Host "setup v9 complete"
