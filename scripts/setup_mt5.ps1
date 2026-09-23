# MT5 setup v10: seed plaintext MCP ApiKey + lock assistant.ini read-only.
# Local proof (2026-09-23): plaintext key + attrib read-only + restart => probe 200.
# Without read-only, MT5 rewrites ApiKey to 168-hex on start and auth 401s.

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

Write-Host "[3] writing login.ini + assistant.ini (plaintext ApiKey + read-only)..."
$cfgDir = Join-Path $dir "Config"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
@"
[Common]
Login=$login
Password=$pass
Server=$server
"@ | Set-Content -Path (Join-Path $cfgDir "alpha_login.ini") -Encoding ASCII

# Local-verified seed: plaintext GUI-format key. Random per run so we own the secret.
# Never start with '-': argparse treats "KEY" after --seed-key as a flag (v10 runner bug).
$bytes = New-Object byte[] 31
try {
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
} catch {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
}
for ($try = 0; $try -lt 32; $try++) {
    $seedKey = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    if ($seedKey.Length -ge 40 -and -not $seedKey.StartsWith('-')) { break }
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
}
if ($seedKey.Length -lt 40 -or $seedKey.StartsWith('-')) {
    throw "seed key invalid (len=$($seedKey.Length) dash=$($seedKey.StartsWith('-')))"
}

$asst = Join-Path $cfgDir "assistant.ini"
$ini = @"
[MCP.MetaTrader]
Enable=1
Endpoint=http://127.0.0.1:22346/mcp
ApiKey=$seedKey
[MCP.MetaEditor]
Enable=1
Endpoint=http://127.0.0.1:22345/mcp
ApiKey=$seedKey
"@
# clear any prior readonly from reinstall
if (Test-Path $asst) { (Get-Item $asst).IsReadOnly = $false }
Set-Content -Path $asst -Value $ini -Encoding Unicode
(Get-Item $asst).IsReadOnly = $true
Write-Host "seeded assistant.ini plaintext ApiKey (len=$($seedKey.Length)) + READ-ONLY"

$artDir = Join-Path $env:RUNNER_TEMP "mt5-config"
New-Item -ItemType Directory -Force -Path $artDir | Out-Null

Write-Host "[4] launching terminal /config (auto-login + MCP)..."
$loginIni = Join-Path $cfgDir "alpha_login.ini"
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"

# Primary: probe our seed key immediately (server should load plaintext from read-only file).
$finder = Join-Path $repoRoot "scripts\find_mcp_key.py"
function Invoke-KeyFind([string]$label, [string]$url, [string]$extraArgs = "") {
    Write-Host "$label discovering MCP key at $url ..."
    # equals-form: space form breaks if value starts with '-' (argparse flag)
    $argList = @($finder, "--url=$url", "--wait=150", "--rescan=6", "--seed-key=$seedKey")
    if ($extraArgs) { $argList += $extraArgs -split ' ' }
    $out = & python @argList 2>&1
    $exit = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }
    if ($exit -ne 0) { return $null }
    $k = (@($out) | Where-Object { $_ -match '^[A-Za-z0-9_-]{40,64}$' -and $_ -ne '' } | Select-Object -Last 1)
    return $k
}

function Save-ConfigDiag {
    if (Test-Path $asst) {
        Copy-Item $asst (Join-Path $artDir "assistant.ini") -Force -ErrorAction SilentlyContinue
        $txt = Get-Content $asst -Raw -ErrorAction SilentlyContinue
        if ($txt -match '(?im)ApiKey\s*=\s*(\S+)') {
            $v = $Matches[1]
            Write-Host ("assistant.ini ApiKey present len={0} hex_like={1} readonly={2}" -f `
                $v.Length, ($v -match '^[0-9a-fA-F]+$'), (Get-Item $asst).IsReadOnly)
        }
        Write-Host ("assistant.ini bytes={0}" -f (Get-Item $asst).Length)
    } else {
        Write-Host "assistant.ini missing at $asst"
    }
    $roaming = Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Recurse -Filter assistant.ini -ErrorAction SilentlyContinue
    foreach ($f in $roaming) {
        Copy-Item $f.FullName (Join-Path $artDir ("assistant_" + $f.Directory.Name + ".ini")) -Force -ErrorAction SilentlyContinue
        $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($txt -match '(?im)ApiKey\s*=\s*(\S+)') {
            Write-Host ("roaming {0} ApiKey len={1}" -f $f.FullName, $Matches[1].Length)
        }
    }
    $logRoots = @("$env:APPDATA\MetaQuotes\Terminal", (Join-Path $dir "logs"))
    foreach ($lr in $logRoots) {
        if (Test-Path $lr) {
            Get-ChildItem $lr -Recurse -Filter *.log -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 4 |
                ForEach-Object { Copy-Item $_.FullName (Join-Path $artDir $_.Name) -Force -ErrorAction SilentlyContinue }
        }
    }
}

$key = Invoke-KeyFind "[5]" "http://127.0.0.1:22346/mcp"
Save-ConfigDiag

if (-not $key) {
    Write-Host "[6] restart terminal (reload read-only plaintext key) + retry..."
    Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
    # re-apply seed if MT5 somehow made it writable and rewrote
    if (Test-Path $asst) {
        try {
            (Get-Item $asst).IsReadOnly = $false
            $cur = Get-Content $asst -Raw -ErrorAction SilentlyContinue
            if ($cur -notmatch [regex]::Escape($seedKey)) {
                $ini2 = @"
[MCP.MetaTrader]
Enable=1
Endpoint=http://127.0.0.1:22346/mcp
ApiKey=$seedKey
[MCP.MetaEditor]
Enable=1
Endpoint=http://127.0.0.1:22345/mcp
ApiKey=$seedKey
"@
                Set-Content -Path $asst -Value $ini2 -Encoding Unicode
                Write-Host "re-seeded plaintext ApiKey"
            }
            (Get-Item $asst).IsReadOnly = $true
        } catch {
            Write-Host "readonly re-apply warning: $_"
        }
    }
    Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"
    $key = Invoke-KeyFind "[7]" "http://127.0.0.1:22346/mcp"
    Save-ConfigDiag
}

if (-not $key) {
    # last resort: seed-key direct probe once more after short wait
    Write-Host "[8] direct seed-key probe..."
    $out = & python $finder "--url=http://127.0.0.1:22346/mcp" "--wait=30" "--rescan=4" "--seed-key=$seedKey" 2>&1
    $out | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -eq 0) {
        $key = (@($out) | Where-Object { $_ -match '^[A-Za-z0-9_-]{40,64}$' } | Select-Object -Last 1)
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
Write-Host "setup v10 complete"
