#!/usr/bin/env bash
# Deploy / refresh the shared edge on this host: ONE Traefik owning :80/:443 for
# every compose tenant, plus (optionally) the shared MySQL they can share.
# Run this once per host BEFORE deploying tenants — deploy.sh calls it for you if
# the edge is missing. Re-running is safe (keeps the ACME store + DB volume).
#
#   deploy-edge.sh --acme-email <e> [--tls-mode le|cloudflare|le-dns-cloudflare]
#                  [--cf-dns-token <t>] [--shared-db] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

ACME_EMAIL=""; TLS_MODE="le"; CF_DNS_TOKEN=""; SHARED_DB=false; DRY_RUN=false
while [[ $# -gt 0 ]]; do case "$1" in
  --acme-email) ACME_EMAIL="$2"; shift 2 ;;
  --tls-mode) TLS_MODE="$2"; shift 2 ;;
  --cf-dns-token) CF_DNS_TOKEN="$2"; shift 2 ;;
  --shared-db) SHARED_DB=true; shift ;;
  --dry-run) DRY_RUN=true; shift ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  *) fail "Unknown option: $1" ;;
esac; done

require_docker
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is required. Run: kutab-deploy bootstrap-vm"

EDGE_DIR="$DATA_ROOT/envs/_edge"
mkdir -p "$EDGE_DIR"; chmod 700 "$EDGE_DIR"
COMPOSE="$PROVIDER_ROOT/templates/edge-stack.compose.yml"

# reuse the existing email when re-running without --acme-email
if [[ -z "$ACME_EMAIL" && -f "$EDGE_DIR/.env" ]]; then
  ACME_EMAIL="$(grep -E '^ACME_EMAIL=' "$EDGE_DIR/.env" | cut -d= -f2- || true)"
fi
[[ -n "$ACME_EMAIL" ]] || fail "--acme-email is required the first time (Let's Encrypt registration)"

# shared MySQL root password: generate once, then keep it
ROOT_PW_FILE="$DATA_ROOT/secrets/shared_db_root_password"
mkdir -p "$(dirname "$ROOT_PW_FILE")"; chmod 700 "$DATA_ROOT/secrets" 2>/dev/null || true
if [[ ! -f "$ROOT_PW_FILE" ]]; then
  ( umask 077; password > "$ROOT_PW_FILE" ); chmod 600 "$ROOT_PW_FILE"
  log "Generated shared DB root password → $ROOT_PW_FILE"
fi
SHARED_DB_ROOT_PASSWORD="$(cat "$ROOT_PW_FILE")"
BP_MB="$(suggested_buffer_pool_mb)"

cat > "$EDGE_DIR/.env" <<EOF
KUTAB_EDGE_DIR=$EDGE_DIR
ACME_EMAIL=$ACME_EMAIL
SHARED_DB_ROOT_PASSWORD=$SHARED_DB_ROOT_PASSWORD
SHARED_DB_BUFFER_POOL=${BP_MB}M
EOF
chmod 600 "$EDGE_DIR/.env"

# host-level TLS: one Traefik serves every tenant on this box
write_traefik_env "$EDGE_DIR" "$ACME_EMAIL" "$TLS_MODE" "$CF_DNS_TOKEN"
log "Edge TLS mode: $TLS_MODE"

compose=(docker compose -p kutab-edge --env-file "$EDGE_DIR/.env" -f "$COMPOSE")
[[ "$SHARED_DB" == true ]] && compose+=(--profile shared-db)

if [[ "$DRY_RUN" == true ]]; then
  "${compose[@]}" config >/dev/null && ok "edge compose config is valid" || fail "edge compose config invalid"
  exit 0
fi

dbsfx=""; [[ "$SHARED_DB" == true ]] && dbsfx=" + shared MySQL"
log "Bringing up the shared edge (Traefik${dbsfx})"
"${compose[@]}" pull --quiet 2>/dev/null || true
"${compose[@]}" up -d

node_state_set PROVIDER compose
node_state_set EDGE 1
[[ "$SHARED_DB" == true ]] && node_state_set SHARED_DB 1
ok "Edge is up. Traefik owns :80/:443 on the 'kutab-shared' network — tenants bind no host ports."
