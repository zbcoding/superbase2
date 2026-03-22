#!/bin/bash
#
# SuperBase² — one-command installer
#
# Installs and starts self-hosted Supabase with multi-project support.
#
# Usage:
#   ./install.sh                    Interactive setup
#   ./install.sh --auto             Auto-generate all secrets, no prompts
#   ./install.sh --project myapp    Auto-setup + create a first project
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[SuperBase²]${NC} $1"; }
ok()    { echo -e "${GREEN}[SuperBase²]${NC} $1"; }
warn()  { echo -e "${YELLOW}[SuperBase²]${NC} $1"; }
err()   { echo -e "${RED}[SuperBase²]${NC} $1"; }

# ─── Parse args ──────────────────────────────────────────────────────────────

AUTO=false
FIRST_PROJECT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)
            AUTO=true
            shift
            ;;
        --project)
            FIRST_PROJECT="$2"
            AUTO=true
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--auto] [--project <name>]"
            echo ""
            echo "Options:"
            echo "  --auto              Auto-generate all secrets, skip prompts"
            echo "  --project <name>    Auto-setup and create a first project"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ─── Preflight checks ───────────────────────────────────────────────────────

info "Checking prerequisites..."

if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed. Install it first: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose v2 is not available. Update Docker or install the compose plugin."
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    err "openssl is required but not found."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running. Start Docker first."
    exit 1
fi

ok "Prerequisites OK"

# ─── Generate .env if needed ────────────────────────────────────────────────

cd "$DOCKER_DIR"

if [ -f .env ]; then
    # Check if it's still the example defaults
    if grep -q "your-super-secret-and-long-postgres-password" .env 2>/dev/null; then
        warn ".env exists but has default secrets — regenerating"
        NEEDS_SECRETS=true
    else
        info ".env already configured"
        NEEDS_SECRETS=false
    fi
else
    info "Creating .env from template..."
    cp .env.example .env
    NEEDS_SECRETS=true
fi

if [ "$NEEDS_SECRETS" = true ]; then
    info "Generating secrets..."
    sh utils/generate-keys.sh --update-env
    ok "Secrets generated and written to .env"
fi

# ─── Configure domain (interactive only) ────────────────────────────────────

if [ "$AUTO" = false ]; then
    echo ""
    echo -e "${BOLD}Domain configuration${NC}"
    echo "  Current: $(grep '^SUPABASE_PUBLIC_URL=' .env | cut -d= -f2)"
    echo ""
    read -r -p "Enter your domain (or press Enter for localhost:8000): " domain

    if [ -n "$domain" ]; then
        # Strip trailing slash
        domain="${domain%/}"
        # Add https:// if no protocol
        if [[ ! "$domain" =~ ^https?:// ]]; then
            domain="https://$domain"
        fi
        sed -i.bak \
            -e "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=$domain|" \
            -e "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=$domain|" \
            .env
        rm -f .env.bak
        ok "Domain set to $domain"
    fi
fi

# ─── Initialize empty manifest ──────────────────────────────────────────────

if [ ! -f "$SCRIPT_DIR/projects.json" ]; then
    echo '{ "projects": [] }' > "$SCRIPT_DIR/projects.json"
fi

# ─── Pull images ────────────────────────────────────────────────────────────

info "Pulling Docker images (this may take a few minutes)..."
docker compose -f docker-compose.yml -f docker-compose.superbase2.yml pull
ok "Images pulled"

# ─── Start shared infrastructure ────────────────────────────────────────────

info "Starting shared infrastructure..."
docker compose -f docker-compose.yml -f docker-compose.superbase2.yml up -d
ok "Shared infrastructure running"

# ─── Wait for Postgres to be ready ──────────────────────────────────────────

info "Waiting for Postgres to be ready..."
for i in $(seq 1 30); do
    if docker exec supabase-db pg_isready -U postgres -h localhost >/dev/null 2>&1; then
        ok "Postgres is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        err "Postgres failed to start within 30 seconds"
        err "Check: docker logs supabase-db"
        exit 1
    fi
    sleep 1
done

# ─── Create first project if requested ──────────────────────────────────────

if [ -n "$FIRST_PROJECT" ]; then
    info "Creating project: $FIRST_PROJECT"
    bash "$SCRIPT_DIR/superbase2.sh" create "$FIRST_PROJECT"

    info "Starting project containers..."
    bash "$SCRIPT_DIR/superbase2.sh" up "$FIRST_PROJECT"

    ok "Project '$FIRST_PROJECT' is running"
fi

# ─── Interactive: offer to create a project ──────────────────────────────────

if [ "$AUTO" = false ] && [ -z "$FIRST_PROJECT" ]; then
    echo ""
    read -r -p "Create a project now? (name or Enter to skip): " proj_name

    if [ -n "$proj_name" ]; then
        bash "$SCRIPT_DIR/superbase2.sh" create "$proj_name"
        bash "$SCRIPT_DIR/superbase2.sh" up "$proj_name"
        FIRST_PROJECT="$proj_name"
    fi
fi

# ─── Done ────────────────────────────────────────────────────────────────────

PUBLIC_URL=$(grep '^SUPABASE_PUBLIC_URL=' .env | cut -d= -f2)

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  SuperBase² is running!${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Dashboard:  ${CYAN}${PUBLIC_URL}${NC}"
echo -e "  Username:   $(grep '^DASHBOARD_USERNAME=' .env | cut -d= -f2)"
echo -e "  Password:   $(grep '^DASHBOARD_PASSWORD=' .env | cut -d= -f2)"
echo ""

if [ -n "$FIRST_PROJECT" ]; then
    echo -e "  ${BOLD}Project '$FIRST_PROJECT':${NC}"
    bash "$SCRIPT_DIR/superbase2.sh" client-config "$FIRST_PROJECT"
fi

echo -e "  ${BOLD}Commands:${NC}"
echo "    ./superbase2.sh create <name>    Create a project"
echo "    ./superbase2.sh list             List projects"
echo "    ./superbase2.sh up <name>        Start a project"
echo "    ./superbase2.sh client-config <name>"
echo ""
echo -e "  ${BOLD}Upgrade Supabase:${NC}"
echo "    git pull upstream master"
echo "    docker compose -f docker-compose.yml -f docker-compose.superbase2.yml pull"
echo "    docker compose -f docker-compose.yml -f docker-compose.superbase2.yml up -d"
echo ""
