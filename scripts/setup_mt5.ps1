# MT5 setup v4: PORTABLE mode (all data inside install dir -> deterministic
# paths) + login/MCP pre-seed + port probe. No APPDATA guessing.

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

$asst = Join-Path $cfgDir "assistant.ini"
@"
[MCP.MetaTrader]
Enabled=1
ApiKey=$key
"@ | Set-Content -Path $asst -Encoding ASCII
Write-Host "config written: $asst"

Write-Host "[4] launching terminal /portable /config (auto-login + MCP)..."
Start-Process -FilePath $term -ArgumentList "/portable", "/config:$loginIni"

Write-Host "[5] waiting for MCP port 22346..."
$alive = $false
foreach ($i in 1..12) {
    Start-Sleep -Seconds 10
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:22346/mcp" -Method Get `
            -Headers @{Authorization = "Bearer $key"} -TimeoutSec 5 -SkipHttpErrorCheck
        Write-Host ("  try {0}: HTTP {1}" -f $i, $r.StatusCode)
        if ($r.StatusCode -in 400,401,403,405,426) { $alive = $true; break }
    } catch {
        Write-Host ("  try {0}: {1}" -f $i, $_.Exception.Message)
    }
}
if ($alive) { Write-Host "MCP_PORT_PROBE: ALIVE" }
else {
    Write-Host "MCP_PORT_PROBE: DEAD"
    Get-Process terminal64 -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("terminal process running: PID " + $_.Id)
    }
    throw "MCP server did not come up (see probe lines above)"
}
Write-Host "setup v4 complete -- MCP ALIVE"
