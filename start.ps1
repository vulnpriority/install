# start.ps1
# VulnPriority installer and launcher for Windows
#
# Usage (first install) - run in PowerShell:
#   irm https://raw.githubusercontent.com/vulnpriority/install/main/start.ps1 | iex
#
# Usage (update):
#   irm https://raw.githubusercontent.com/vulnpriority/install/main/start.ps1 | iex

$ErrorActionPreference = "Stop"

function Write-Ok   { param($msg) Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Info { param($msg) Write-Host "→ $msg" -ForegroundColor Cyan }
function Write-Warn { param($msg) Write-Host "⚠ $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "✗ $msg" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  VulnPriority" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

# Step 1: Check Docker
Write-Info "Checking Docker..."
try {
    $null = Get-Command docker -ErrorAction Stop
} catch {
    Write-Fail "Docker is not installed. Install Docker Desktop from https://docker.com and try again."
}
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Fail "Docker is not running. Start Docker Desktop and try again."
}
Write-Ok "Docker is running"

# Step 2: Check registry access
Write-Info "Checking registry access..."
$pullTest = docker pull ghcr.io/vulnpriority/vulnpriority-backend:latest --quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Cannot access VulnPriority registry. Run: docker login ghcr.io -u vulnpriority --password YOUR_TOKEN"
}
Write-Ok "Registry access confirmed"

# Step 3: Create install directory
$InstallDir = "C:\vulnpriority"
Write-Info "Setting up install directory at $InstallDir..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir
Write-Ok "Install directory ready"

# Step 4: Download docker-compose.yml
Write-Info "Downloading docker-compose.yml..."
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/vulnpriority/install/main/docker-compose.yml" `
    -OutFile "docker-compose.yml" -UseBasicParsing
Write-Ok "docker-compose.yml downloaded"

# Step 5: Generate .env (first install only)
if (-not (Test-Path ".env")) {
    Write-Info "Generating .env with random secrets..."

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    $dbBytes = New-Object byte[] 32
    $rng.GetBytes($dbBytes)
    $DbPassword = [BitConverter]::ToString($dbBytes).Replace("-", "").ToLower()

    $jwtBytes = New-Object byte[] 64
    $rng.GetBytes($jwtBytes)
    $JwtSecret = [BitConverter]::ToString($jwtBytes).Replace("-", "").ToLower()

    $envContent = "POSTGRES_DB=vulnpriority`nPOSTGRES_USER=vulnpriority`nPOSTGRES_PASSWORD=$DbPassword`nJWT_SECRET_KEY=$JwtSecret`nENVIRONMENT=production`nNVD_API_KEY=`nVULNCHECK_API_KEY=`nGITHUB_TOKEN=`nOTX_API_KEY=`nTSC_HOST=`nTSC_ACCESS_KEY=`nTSC_SECRET_KEY=`nTSC_VERIFY_SSL=false`n"

    # Write UTF-8 WITHOUT BOM — critical for Docker to read correctly
    [System.IO.File]::WriteAllText("$InstallDir\.env", $envContent, [System.Text.UTF8Encoding]::new($false))

    Write-Ok ".env generated with random secrets"
} else {
    Write-Ok ".env already exists — keeping existing"
}

# Step 6: Generate SSL certificate (first install only)
$certsDir = "certs"
if (-not (Test-Path "$certsDir\cert.pem") -or -not (Test-Path "$certsDir\key.pem")) {
    Write-Info "Generating SSL certificate..."
    New-Item -ItemType Directory -Force -Path $certsDir | Out-Null

    $ServerIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch "Loopback" -and $_.IPAddress -notmatch "^169" } |
        Select-Object -First 1).IPAddress
    if (-not $ServerIP) { $ServerIP = "127.0.0.1" }

    docker run --rm `
        -v "${InstallDir}\certs:/certs" `
        alpine sh -c "apk add --no-cache openssl -q 2>/dev/null && openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout /certs/key.pem -out /certs/cert.pem -subj '/CN=VulnPriority/O=VulnPriority/C=AE' -addext 'subjectAltName=IP:$ServerIP,IP:127.0.0.1,DNS:localhost' 2>/dev/null"

    Write-Ok "SSL certificate generated for IP: $ServerIP (valid 10 years)"
    Write-Warn "Browser will show a security warning on first visit."
    Write-Warn "Click Advanced -> Proceed to continue."
} else {
    Write-Ok "SSL certificate already exists — keeping existing"
}

# Step 7: Pull latest images
Write-Info "Pulling latest images..."
docker compose pull
Write-Ok "Images up to date"

# Step 8: Start containers
Write-Info "Starting VulnPriority..."
docker compose up -d
Write-Ok "VulnPriority is starting"

# Wait for backend
Write-Info "Waiting for backend to be ready (about 60 seconds)..."
$attempts = 0
$maxAttempts = 30
do {
    Start-Sleep -Seconds 5
    $attempts++
    $health = docker exec vulnpriority-backend curl -sf http://localhost:8000/ 2>&1
    if ($LASTEXITCODE -eq 0) { break }
} while ($attempts -lt $maxAttempts)

if ($attempts -lt $maxAttempts) {
    Write-Ok "Backend is ready"
} else {
    Write-Warn "Backend is taking longer than expected."
    Write-Warn "Check logs with: docker compose -f C:\vulnpriority\docker-compose.yml logs -f backend"
}

# Done
$ServerIP = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notmatch "Loopback" -and $_.IPAddress -notmatch "^169" } |
    Select-Object -First 1).IPAddress
if (-not $ServerIP) { $ServerIP = "localhost" }

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  VulnPriority is running!" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
Write-Host "  Open: https://$ServerIP" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Accept the certificate warning to continue."
Write-Host "  Complete the setup wizard to create your admin account."
Write-Host ""
Write-Host "  Useful commands:"
Write-Host "    Logs:    docker compose -f C:\vulnpriority\docker-compose.yml logs -f"
Write-Host "    Stop:    docker compose -f C:\vulnpriority\docker-compose.yml down"
Write-Host "    Update:  irm https://raw.githubusercontent.com/vulnpriority/install/main/start.ps1 | iex"
Write-Host ""
