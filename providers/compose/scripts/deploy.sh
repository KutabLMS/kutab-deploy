#!/usr/bin/env bash
# Deploy ONE Kutab tenant on a compose host. Binds no host ports: the shared edge
# (deploy-edge.sh — one Traefik owning :80/:443 for the whole host) routes to it,
# which is what lets MANY tenant boxes run side by side. The edge is brought up
# automatically if it isn't there yet.
#
#   deploy.sh <name> --tenant-domain <d> --acme-email <e>
#            [--channel latest|dev|<tag>] [--db-mode bundled|shared|host]
#            [--custom-domain <d>] [--with-whatsapp]
#            [--tls-mode le|cloudflare|le-dns-cloudflare] [--cf-dns-token <t>]
#            [--backend-image ..] [--frontend-image ..] [--nginx-image ..]
#            [--skip-migrate] [--dry-run]
#
# --channel picks which built images to run (CI tags master→latest, dev→dev):
#   latest (default) | dev | any explicit tag. An explicit --backend-image etc wins.
# --db-mode picks the database:
#   bundled  a MySQL container inside this tenant's stack (default; most isolated)
#   shared   the host's shared MySQL on the edge (kutab-db) — best when packing
#            several tenants on one box; each tenant gets its own DB + user
#   host     a MariaDB installed on the host itself (see setup-db --mode host)
#   Defaults to `host` if the node records DB_MODE=host, else `bundled`.
# --tls-mode / --cf-dns-token are HOST-level (Traefik is shared) and only apply
# when this run has to bring the edge up; change later with set-tls.sh:
#   le               Let's Encrypt HTTP-01 (default) — domain points at this box.
#   cloudflare       self-signed origin; client's Cloudflare serves the real cert
#                    (set SSL/TLS = Full). No token — scales to any client count.
#   le-dns-cloudflare  Let's Encrypt DNS-01 (needs --cf-dns-token for that zone).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

NAME="${1:-}"; [[ $# -gt 0 ]] && shift
TENANT_DOMAIN=""; CUSTOM_DOMAIN=""; ACME_EMAIL=""; PLATFORM_BASE_DOMAIN=""
CHANNEL="${CHANNEL:-latest}"
BACKEND_IMAGE="${BACKEND_IMAGE:-}"; FRONTEND_IMAGE="${FRONTEND_IMAGE:-}"; NGINX_IMAGE="${NGINX_IMAGE:-}"
WITH_WHATSAPP=false; SKIP_MIGRATE=false; DRY_RUN=false; DB_MODE=""
TLS_MODE="le"; CF_DNS_TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-domain) TENANT_DOMAIN="$2"; shift 2 ;;
    --platform-base-domain) PLATFORM_BASE_DOMAIN="$2"; shift 2 ;;
    --custom-domain) CUSTOM_DOMAIN="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --db-mode) DB_MODE="$2"; shift 2 ;;
    --tls-mode) TLS_MODE="$2"; shift 2 ;;
    --cf-dns-token) CF_DNS_TOKEN="$2"; shift 2 ;;
    --backend-image) BACKEND_IMAGE="$2"; shift 2 ;;
    --frontend-image) FRONTEND_IMAGE="$2"; shift 2 ;;
    --nginx-image) NGINX_IMAGE="$2"; shift 2 ;;
    --with-whatsapp) WITH_WHATSAPP=true; shift ;;
    --host-db) DB_MODE=host; shift ;;         # back-compat alias
    --bundled-db) DB_MODE=bundled; shift ;;   # back-compat alias
    --skip-migrate) SKIP_MIGRATE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

# images follow the channel unless one was pinned explicitly
BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/uni-devs/kutab-api:$CHANNEL}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/uni-devs/kutab-front:$CHANNEL}"
NGINX_IMAGE="${NGINX_IMAGE:-ghcr.io/uni-devs/kutab-api-nginx:$CHANNEL}"

require_slug "$NAME"
require_docker
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is required. Run: kutab-deploy bootstrap-vm"
[[ -z "$TENANT_DOMAIN" && -n "$PLATFORM_BASE_DOMAIN" ]] && TENANT_DOMAIN="$NAME.$PLATFORM_BASE_DOMAIN"
[[ -n "$TENANT_DOMAIN" ]] || fail "--tenant-domain (or --platform-base-domain) is required"
[[ -n "$ACME_EMAIL" ]] || fail "--acme-email is required (Let's Encrypt registration)"

# default DB mode from what this node has (a host install → use the host DB)
if [[ -z "$DB_MODE" ]]; then
  [[ "$(node_state_get DB_MODE)" == host ]] && DB_MODE=host || DB_MODE=bundled
fi
case "$DB_MODE" in
  bundled) DB_HOST_VALUE="mysql" ;;
  shared)  DB_HOST_VALUE="kutab-db" ;;              # shared MySQL on the edge
  host)    DB_HOST_VALUE="host.docker.internal" ;;
  *) fail "Unknown --db-mode '$DB_MODE' (use bundled|shared|host)" ;;
esac
HOST_DB_ROOT_PW_FILE="$(kutab_data_dir)/providers/swarm/secrets/infrastructure/host_db_root_password"

API_DOMAIN="api.$TENANT_DOMAIN"; WS_DOMAIN="ws.$TENANT_DOMAIN"
SQL_SLUG="$(printf '%s' "$NAME" | tr '-' '_' | tr -cd '[:alnum:]_')"
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"
DEPLOY_DIR="$DATA_ROOT/envs/$NAME"
EDGE_DIR="$DATA_ROOT/envs/_edge"
COMPOSE="$PROVIDER_ROOT/templates/single-stack.compose.yml"
BP_MB="$(suggested_buffer_pool_mb)"

# ── the shared edge owns :80/:443 for every tenant on this host — bring it up if
# it's missing, so a first deploy still works end to end.
if ! docker network inspect kutab-shared >/dev/null 2>&1; then
  log "Shared edge not found — bringing it up (Traefik${DB_MODE:+, db-mode $DB_MODE})"
  edge_args=(--acme-email "$ACME_EMAIL" --tls-mode "$TLS_MODE")
  [[ -n "$CF_DNS_TOKEN" ]] && edge_args+=(--cf-dns-token "$CF_DNS_TOKEN")
  [[ "$DB_MODE" == shared ]] && edge_args+=(--shared-db)
  [[ "$DRY_RUN" == true ]] && edge_args+=(--dry-run)
  bash "$SCRIPT_DIR/deploy-edge.sh" "${edge_args[@]}" || fail "Could not bring up the shared edge"
elif [[ "$DB_MODE" == shared ]] && ! docker ps --format '{{.Names}}' | grep -q '^kutab-edge-mysql-1$'; then
  log "--db-mode shared but the edge has no shared MySQL — starting it"
  bash "$SCRIPT_DIR/deploy-edge.sh" --shared-db || fail "Could not start the shared MySQL on the edge"
fi

host_rule() { local r=""; for h in "$@"; do [[ -n "$h" ]] || continue; if [[ -z "$r" ]]; then r="Host(\`$h\`)"; else r="$r || Host(\`$h\`)"; fi; done; printf '%s' "$r"; }

mkdir -p "$DEPLOY_DIR"; chmod 700 "$DEPLOY_DIR"

# ── generate env files once (idempotent) ───────────────────────────────────────
if [[ ! -f "$DEPLOY_DIR/backend.env" ]]; then
  APP_KEY="base64:$(openssl rand -base64 32)"
  JWT_SECRET="$(password)"; DB_PASSWORD="$(password)"; MYSQL_ROOT_PASSWORD="$(password)"; REDIS_PASSWORD="$(password)"
  REVERB_APP_ID="$(password)"; REVERB_APP_KEY="$(password)"; REVERB_APP_SECRET="$(password)"
  cat > "$DEPLOY_DIR/backend.env" <<EOF
APP_NAME="$NAME"
APP_ENV=production
APP_KEY=$APP_KEY
APP_DEBUG=false
KUTAB_TENANT_NAME=$NAME
METRICS_ENABLED=true
APP_URL=https://$TENANT_DOMAIN
APP_FRONTEND_URL=https://$TENANT_DOMAIN
JWT_SECRET=$JWT_SECRET
DB_CONNECTION=mysql
DB_HOST=$DB_HOST_VALUE
DB_PORT=3306
DB_DATABASE=kutab_$SQL_SLUG
DB_USERNAME=kutab_$SQL_SLUG
DB_PASSWORD=$DB_PASSWORD
REDIS_HOST=valkey
REDIS_PORT=6379
REDIS_PASSWORD=$REDIS_PASSWORD
QUEUE_CONNECTION=redis
CACHE_STORE=redis
SESSION_DRIVER=redis
REVERB_APP_ID=$REVERB_APP_ID
REVERB_APP_KEY=$REVERB_APP_KEY
REVERB_APP_SECRET=$REVERB_APP_SECRET
REVERB_HOST=$WS_DOMAIN
REVERB_PORT=443
REVERB_SCHEME=https
REVERB_SCALING_ENABLED=true
LOG_CHANNEL=stderr
LOG_LEVEL=info
EOF
  cat > "$DEPLOY_DIR/frontend.env" <<EOF
NUXT_PUBLIC_APP_URL=https://$TENANT_DOMAIN
NUXT_PUBLIC_API_BASE=https://$API_DOMAIN/api
NUXT_PUBLIC_REVERB_HOST=$WS_DOMAIN
NUXT_PUBLIC_REVERB_PORT=443
NUXT_PUBLIC_REVERB_SCHEME=https
NUXT_PUBLIC_REVERB_APP_KEY=$REVERB_APP_KEY
EOF
  chmod 600 "$DEPLOY_DIR/backend.env" "$DEPLOY_DIR/frontend.env"
  log "Generated env files in $DEPLOY_DIR"
else
  log "Using existing env files in $DEPLOY_DIR"
fi

# pull DB creds + redis pw back out of backend.env for the compose .env
DB_DATABASE="$(grep -E '^DB_DATABASE=' "$DEPLOY_DIR/backend.env" | cut -d= -f2-)"
DB_USERNAME="$(grep -E '^DB_USERNAME=' "$DEPLOY_DIR/backend.env" | cut -d= -f2-)"
DB_PASSWORD="$(grep -E '^DB_PASSWORD=' "$DEPLOY_DIR/backend.env" | cut -d= -f2-)"
MYSQL_ROOT_PASSWORD="$( [[ -f "$DEPLOY_DIR/.mysql_root" ]] && cat "$DEPLOY_DIR/.mysql_root" || password )"
( umask 077; printf '%s' "$MYSQL_ROOT_PASSWORD" > "$DEPLOY_DIR/.mysql_root" )

# ── provision the tenant DB + user on whichever shared server we point at ───────
# (bundled mode needs nothing — the container creates its own DB from MYSQL_* env)
tenant_db_sql() {
  cat <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_DATABASE\`.* TO '$DB_USERNAME'@'%';
FLUSH PRIVILEGES;
SQL
}

if [[ "$DB_MODE" == host && "$DRY_RUN" != true ]]; then
  log "Host DB mode: provisioning '$DB_DATABASE' on the host MariaDB"
  have mariadb || have mysql || fail "--db-mode host needs the mariadb/mysql client on the host. Run: kutab-deploy swarm setup-db --mode host"
  [[ -f "$HOST_DB_ROOT_PW_FILE" ]] || fail "Host DB root password not found ($HOST_DB_ROOT_PW_FILE). Install it: kutab-deploy swarm setup-db --mode host --bind 172.17.0.1"
  host_root_pw="$(cat "$HOST_DB_ROOT_PW_FILE")"; db_cli=mariadb; have mariadb || db_cli=mysql
  tenant_db_sql | "$db_cli" -uroot -p"$host_root_pw" || warn "Host DB provisioning failed — create $DB_DATABASE manually."
fi

if [[ "$DB_MODE" == shared && "$DRY_RUN" != true ]]; then
  log "Shared DB mode: provisioning '$DB_DATABASE' on the edge MySQL (kutab-db)"
  shared_pw_file="$DATA_ROOT/secrets/shared_db_root_password"
  [[ -f "$shared_pw_file" ]] || fail "Shared DB root password not found ($shared_pw_file). Run: kutab-deploy compose deploy-edge --shared-db"
  shared_root_pw="$(cat "$shared_pw_file")"
  for _ in $(seq 1 30); do
    if tenant_db_sql | docker exec -i kutab-edge-mysql-1 mysql -uroot -p"$shared_root_pw" 2>/dev/null; then
      shared_ok=true; break
    fi
    sleep 4
  done
  [[ "${shared_ok:-false}" == true ]] || fail "Could not reach the shared MySQL (kutab-edge-mysql-1). Is the edge up with --shared-db?"
fi

# ── compose interpolation env ──────────────────────────────────────────────────
cat > "$DEPLOY_DIR/.env" <<EOF
TENANT_NAME=$NAME
KUTAB_ENV_DIR=$DEPLOY_DIR
TENANT_DOMAIN=$TENANT_DOMAIN
CUSTOM_DOMAIN=$CUSTOM_DOMAIN
ACME_EMAIL=$ACME_EMAIL
CHANNEL=$CHANNEL
DB_MODE=$DB_MODE
BACKEND_IMAGE=$BACKEND_IMAGE
FRONTEND_IMAGE=$FRONTEND_IMAGE
NGINX_IMAGE=$NGINX_IMAGE
DB_DATABASE=$DB_DATABASE
DB_USERNAME=$DB_USERNAME
DB_PASSWORD=$DB_PASSWORD
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
DB_BUFFER_POOL=${BP_MB}M
API_HOST_RULE=$(host_rule "$API_DOMAIN")
WS_HOST_RULE=$(host_rule "$WS_DOMAIN")
FRONTEND_HOST_RULE=$(host_rule "$TENANT_DOMAIN" "$CUSTOM_DOMAIN")
EOF
chmod 600 "$DEPLOY_DIR/.env"

# TLS lives on the shared edge now (one Traefik per host) — change it with:
#   kutab-deploy compose set-tls --tls-mode <mode>

compose=(docker compose -p "kutab-$NAME" --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE")
[[ "$DB_MODE" == bundled ]] && compose+=(--profile bundled-db)
[[ "$WITH_WHATSAPP" == true ]] && compose+=(--profile whatsapp)

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run — validating compose config:"
  "${compose[@]}" config >/dev/null && ok "compose config is valid" || fail "compose config invalid"
  exit 0
fi

log "Starting tenant stack '$NAME' ($TENANT_DOMAIN) — channel=$CHANNEL db-mode=$DB_MODE"
"${compose[@]}" pull --quiet 2>/dev/null || true
"${compose[@]}" up -d

if [[ "$SKIP_MIGRATE" != true ]]; then
  log "Waiting for the database, then migrating…"
  sleep 25
  "${compose[@]}" exec -T backend sh -lc 'php artisan migrate --force && php artisan db:seed --force' \
    || warn "Migration step failed — run it manually once MySQL is ready: ${compose[*]} exec backend php artisan migrate --force"
fi
node_state_set PROVIDER compose
node_state_append TENANTS "$NAME"
ok "Tenant '$NAME' is up behind the shared edge. Point DNS at this host, then browse https://$TENANT_DOMAIN"
