#!/bin/bash
# start.sh
# VulnPriority installer and launcher for Linux/Mac
#
# Usage (first install):
#   curl -fsSL https://raw.githubusercontent.com/vulnpriority/vulnpriority/main/start.sh | bash
#
# Usage (update):
#   curl -fsSL https://raw.githubusercontent.com/vulnpriority/vulnpriority/main/start.sh | bash
#
# What this does:
#   1. Checks Docker is installed and running
#   2. Checks Docker is logged in to ghcr.io
#   3. Creates install directory ~/vulnpriority
#   4. Downloads docker-compose.yml
#   5. Generates .env with random secrets (first install only)
#   6. Generates SSL certificate (first install only)
#   7. Pulls latest images from ghcr.io
#   8. Starts all containers
#
# On repeat runs (updates):
#   - Skips .env generation (already exists)
#   - Skips cert generation (already exists)
#   - Pulls latest images
#   - Restarts containers with new images

set -e

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
info() { echo -e "${BLUE}→${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VulnPriority"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Step 1: Check Docker ──────────────────────────────────────
info "Checking Docker..."
command -v docker >/dev/null 2>&1 || fail "Docker is not installed. Install Docker Desktop from https://docker.com and try again."
docker info >/dev/null 2>&1 || fail "Docker is not running. Start Docker Desktop and try again."
ok "Docker is running"

# ── Step 2: Check Docker login ────────────────────────────────
info "Checking registry access..."
docker pull ghcr.io/vulnpriority/vulnpriority-backend:latest --quiet >/dev/null 2>&1 || \
    fail "Cannot access VulnPriority registry. Run: docker login ghcr.io -u vulnpriority --password YOUR_TOKEN"
ok "Registry access confirmed"

# ── Step 3: Create install directory ─────────────────────────
INSTALL_DIR="$HOME/vulnpriority"
info "Setting up install directory at $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
ok "Install directory ready"

# ── Step 4: Download docker-compose.yml ──────────────────────
info "Downloading latest docker-compose.yml..."
curl -fsSL https://raw.githubusercontent.com/vulnpriority/vulnpriority/main/docker-compose.yml \
    -o docker-compose.yml
ok "docker-compose.yml downloaded"

# ── Step 5: Generate .env (first install only) ────────────────
if [ ! -f ".env" ]; then
    info "Generating .env with random secrets..."

    DB_PASSWORD=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 64)

    cat > .env << ENVEOF
POSTGRES_DB=vulnpriority
POSTGRES_USER=vulnpriority
POSTGRES_PASSWORD=${DB_PASSWORD}
JWT_SECRET_KEY=${JWT_SECRET}
ENVIRONMENT=production
NVD_API_KEY=
VULNCHECK_API_KEY=
GITHUB_TOKEN=
OTX_API_KEY=
TSC_HOST=
TSC_ACCESS_KEY=
TSC_SECRET_KEY=
TSC_VERIFY_SSL=false
ENVEOF

    ok ".env generated with random secrets"
else
    ok ".env already exists — keeping existing"
fi

# ── Step 6: Generate SSL certificate (first install only) ─────
if [ ! -f "certs/cert.pem" ] || [ ! -f "certs/key.pem" ]; then
    info "Generating SSL certificate..."
    mkdir -p certs

    # Detect server IP for SAN
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    [ -z "$SERVER_IP" ] && SERVER_IP="127.0.0.1"

    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout certs/key.pem \
        -out certs/cert.pem \
        -subj "/CN=VulnPriority/O=VulnPriority/C=AE" \
        -addext "subjectAltName=IP:${SERVER_IP},IP:127.0.0.1,DNS:localhost" \
        2>/dev/null

    ok "SSL certificate generated for IP: $SERVER_IP (valid 10 years)"
    warn "Browser will show a security warning on first visit."
    warn "Click Advanced → Proceed to continue."
else
    ok "SSL certificate already exists — keeping existing"
fi

# ── Step 7: Pull latest images ────────────────────────────────
info "Pulling latest images from registry..."
docker compose pull
ok "Images up to date"

# ── Step 8: Start containers ──────────────────────────────────
info "Starting VulnPriority..."
docker compose up -d
ok "VulnPriority is starting"

# ── Wait for backend to be healthy ────────────────────────────
info "Waiting for backend to be ready (this takes about 60 seconds)..."
ATTEMPTS=0
MAX_ATTEMPTS=30
until docker exec vulnpriority-backend curl -sf http://localhost:8000/ >/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
        warn "Backend is taking longer than expected."
        warn "Check logs with: docker compose logs -f backend"
        break
    fi
    sleep 5
done

if [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; then
    ok "Backend is ready"
fi

# ── Done ──────────────────────────────────────────────────────
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
[ -z "$SERVER_IP" ] && SERVER_IP="localhost"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}VulnPriority is running!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "  Open: ${BLUE}https://${SERVER_IP}${NC}"
echo ""
echo "  Accept the certificate warning to continue."
echo "  Complete the setup wizard to create your admin account."
echo ""
echo "  Useful commands:"
echo "    Logs:    docker compose -f ~/vulnpriority/docker-compose.yml logs -f"
echo "    Stop:    docker compose -f ~/vulnpriority/docker-compose.yml down"
echo "    Update:  curl -fsSL https://raw.githubusercontent.com/vulnpriority/vulnpriority/main/start.sh | bash"
echo ""