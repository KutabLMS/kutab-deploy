#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"   # node_state_* (local helpers below still win)
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

TENANT_NAME="${1:-}"
[[ $# -gt 0 ]] && shift

PLATFORM_BASE_DOMAIN=""
TENANT_DOMAIN=""
CUSTOM_DOMAIN=""
DISPLAY_NAME=""
FORCE_ENV=false
FORCE_SECRETS=false
SKIP_MIGRATE=false
SHARED_DB=false
DRY_RUN=false

# --channel picks which built images to run (CI tags master→latest, dev→dev).
# An explicit --backend-image / --frontend-image / --nginx-image still wins.
CHANNEL="${CHANNEL:-latest}"
BACKEND_IMAGE="${BACKEND_IMAGE:-}"; FRONTEND_IMAGE="${FRONTEND_IMAGE:-}"; NGINX_IMAGE="${NGINX_IMAGE:-}"
BACKEND_REPLICAS="${BACKEND_REPLICAS:-1}"
FRONTEND_REPLICAS="${FRONTEND_REPLICAS:-1}"
HORIZON_REPLICAS="${HORIZON_REPLICAS:-1}"
NGINX_REPLICAS="${NGINX_REPLICAS:-1}"
REVERB_REPLICAS="${REVERB_REPLICAS:-1}"
APP_POOL="shared"
DB_POOL="shared"
CACHE_POOL="shared"

log() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
password() { openssl rand -base64 36 | tr -d '/+=' | head -c 32; }
slug_sql() { printf '%s' "$1" | tr '-' '_' | tr -cd '[:alnum:]_'; }
docker_config_path() {
  if [[ -n "${DOCKER_CONFIG:-}" ]]; then
    printf '%s/config.json' "$DOCKER_CONFIG"
  else
    printf '%s/.docker/config.json' "$HOME"
  fi
}
validate_docker_credentials() {
  local config_path
  config_path="$(docker_config_path)"

  [[ -f "$config_path" ]] || return

  if grep -q 'docker-credential-desktop\.exe\|desktop\.exe' "$config_path" && ! command -v docker-credential-desktop.exe >/dev/null 2>&1; then
    fail "Docker is configured to use Docker Desktop credential helper in $config_path, but docker-credential-desktop.exe is not available on this Linux host. Remove the desktop credsStore/credHelpers entry and run: docker login ghcr.io -u <github-user> --password-stdin"
  fi
}
ensure_secret() {
  local name="$1"
  local value="$2"
  if docker secret inspect "$name" >/dev/null 2>&1; then
    if [[ "$FORCE_SECRETS" != true ]]; then
      log "Keeping existing secret $name"
      return
    fi
    docker secret rm "$name" >/dev/null
  fi
  printf '%s' "$value" | docker secret create "$name" - >/dev/null
  log "Created secret $name"
}
host_rule() {
  local rule=""
  for host in "$@"; do
    [[ -n "$host" ]] || continue
    if [[ -z "$rule" ]]; then rule="Host(\`$host\`)"; else rule="$rule || Host(\`$host\`)"; fi
  done
  printf '%s' "$rule"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform-base-domain) PLATFORM_BASE_DOMAIN="$2"; shift 2 ;;
    --tenant-domain) TENANT_DOMAIN="$2"; shift 2 ;;
    --custom-domain) CUSTOM_DOMAIN="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --backend-image) BACKEND_IMAGE="$2"; shift 2 ;;
    --frontend-image) FRONTEND_IMAGE="$2"; shift 2 ;;
    --nginx-image) NGINX_IMAGE="$2"; shift 2 ;;
    --backend-replicas) BACKEND_REPLICAS="$2"; shift 2 ;;
    --frontend-replicas) FRONTEND_REPLICAS="$2"; shift 2 ;;
    --worker-replicas) WORKER_REPLICAS="$2"; shift 2 ;;
    --notification-worker-replicas) NOTIFICATION_WORKER_REPLICAS="$2"; shift 2 ;;
    --nginx-replicas) NGINX_REPLICAS="$2"; shift 2 ;;
    --reverb-replicas) REVERB_REPLICAS="$2"; shift 2 ;;
    --app-pool) APP_POOL="$2"; shift 2 ;;
    --db-pool) DB_POOL="$2"; shift 2 ;;
    --cache-pool) CACHE_POOL="$2"; shift 2 ;;
    --force-env) FORCE_ENV=true; shift ;;
    --force-env-regenerate) FORCE_ENV=true; shift ;;
    --force-secrets) FORCE_SECRETS=true; shift ;;
    --skip-secrets) shift ;;
    --skip-migrate) SKIP_MIGRATE=true; shift ;;
    --shared-db) SHARED_DB=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '1,180p' "$PROVIDER_ROOT/README.md"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

# images follow the channel unless one was pinned explicitly
BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/uni-devs/kutab-api:$CHANNEL}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/uni-devs/kutab-front:$CHANNEL}"
NGINX_IMAGE="${NGINX_IMAGE:-ghcr.io/uni-devs/kutab-api-nginx:$CHANNEL}"

[[ "$TENANT_NAME" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ || "$TENANT_NAME" =~ ^[a-z0-9]$ ]] || fail "Invalid tenant name: $TENANT_NAME"
command -v docker >/dev/null || fail "docker is required"
command -v openssl >/dev/null || fail "openssl is required"
if [[ -z "$TENANT_DOMAIN" ]]; then
  [[ -n "$PLATFORM_BASE_DOMAIN" ]] || fail "--platform-base-domain or --tenant-domain is required"
  TENANT_DOMAIN="$TENANT_NAME.$PLATFORM_BASE_DOMAIN"
fi
DISPLAY_NAME="${DISPLAY_NAME:-$TENANT_NAME}"
API_DOMAIN="api.$TENANT_DOMAIN"
WS_DOMAIN="ws.$TENANT_DOMAIN"
SQL_SLUG="$(slug_sql "$TENANT_NAME")"
DB_DATABASE="kutab_$SQL_SLUG"
DB_USERNAME="kutab_$SQL_SLUG"
STACK_NAME="kutab-$TENANT_NAME"
TENANT_DIR="$DATA_ROOT/envs/tenants/$TENANT_NAME"

docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active || fail "Swarm is not active"
docker network inspect kutab-shared >/dev/null 2>&1 || fail "kutab-shared network missing. Run bootstrap-cluster.sh first."
validate_docker_credentials

mkdir -p "$TENANT_DIR"
chmod 700 "$TENANT_DIR"

# Shared DB: provision the DB+user on the cluster's shared MySQL and read the
# generated creds (DB_HOST=kutab-db) from db.env. Dedicated: a per-tenant MySQL.
DB_HOST_VALUE="mysql"
if [[ "$SHARED_DB" == true ]]; then
  log "Shared DB mode: provisioning '$TENANT_NAME' on the shared MySQL (kutab-db)"
  "$SCRIPT_DIR/provision-tenant-db.sh" "$TENANT_NAME" || fail "Shared DB provisioning failed"
  # shellcheck disable=SC1090
  source "$TENANT_DIR/db.env"
  DB_HOST_VALUE="$DB_HOST"
fi

if [[ "$FORCE_ENV" == true || ! -f "$TENANT_DIR/backend.env" ]]; then
  APP_KEY="base64:$(openssl rand -base64 32)"
  JWT_SECRET="$(password)"
  [[ "$SHARED_DB" == true ]] || { DB_PASSWORD="$(password)"; MYSQL_ROOT_PASSWORD="$(password)"; }
  REDIS_PASSWORD="$(password)"
  REVERB_APP_ID="$(password)"
  REVERB_APP_KEY="$(password)"
  REVERB_APP_SECRET="$(password)"

  cat > "$TENANT_DIR/backend.env" <<EOF
APP_NAME="$DISPLAY_NAME"
APP_ENV=production
APP_KEY=$APP_KEY
APP_DEBUG=false
KUTAB_TENANT_NAME=$TENANT_NAME
METRICS_ENABLED=true
APP_URL=https://$TENANT_DOMAIN
APP_FRONTEND_URL=https://$TENANT_DOMAIN
JWT_SECRET=$JWT_SECRET
DB_CONNECTION=mysql
DB_HOST=$DB_HOST_VALUE
DB_PORT=3306
DB_DATABASE=$DB_DATABASE
DB_USERNAME=$DB_USERNAME
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

  cat > "$TENANT_DIR/frontend.env" <<EOF
NUXT_PUBLIC_APP_URL=https://$TENANT_DOMAIN
NUXT_PUBLIC_API_BASE=https://$API_DOMAIN/api
NUXT_PUBLIC_REVERB_HOST=$WS_DOMAIN
NUXT_PUBLIC_REVERB_PORT=443
NUXT_PUBLIC_REVERB_SCHEME=https
NUXT_PUBLIC_REVERB_APP_KEY=$REVERB_APP_KEY
EOF

  chmod 600 "$TENANT_DIR/backend.env" "$TENANT_DIR/frontend.env"
else
  log "Using existing env files in $TENANT_DIR"
fi

# Upsert control-plane platform credentials into backend.env. These arrive via
# the deploy process environment (never as CLI args), so they don't leak into
# process listings. Running on every deploy means existing tenants pick up the
# token and credential rotation just works.
upsert_env() {
  local key="$1" val="$2" file="$3" tmp
  [[ -z "$val" ]] && return 0
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    tmp="$(mktemp)"
    grep -v "^${key}=" "$file" > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}
upsert_env PLATFORM_API_ENABLED "${PLATFORM_API_ENABLED:-}" "$TENANT_DIR/backend.env"
upsert_env PLATFORM_API_TOKEN "${PLATFORM_API_TOKEN:-}" "$TENANT_DIR/backend.env"
upsert_env PLATFORM_SIGNING_SECRET "${PLATFORM_SIGNING_SECRET:-}" "$TENANT_DIR/backend.env"

set -a
# shellcheck disable=SC1091
source "$TENANT_DIR/backend.env"
set +a

if [[ "$SHARED_DB" != true ]]; then
  ensure_secret "${TENANT_NAME}_mysql_password" "$DB_PASSWORD"
  ensure_secret "${TENANT_NAME}_mysql_root_password" "${MYSQL_ROOT_PASSWORD:-$(password)}"
fi

export TENANT_NAME TENANT_DOMAIN CUSTOM_DOMAIN API_DOMAIN WS_DOMAIN
export DB_DATABASE DB_USERNAME
export BACKEND_IMAGE FRONTEND_IMAGE NGINX_IMAGE
export BACKEND_REPLICAS FRONTEND_REPLICAS HORIZON_REPLICAS NGINX_REPLICAS REVERB_REPLICAS
export APP_POOL DB_POOL CACHE_POOL
export API_HOST_RULE="$(host_rule "$API_DOMAIN")"
export WS_HOST_RULE="$(host_rule "$WS_DOMAIN")"
export FRONTEND_HOST_RULE="$(host_rule "$TENANT_DOMAIN" "$CUSTOM_DOMAIN")"
export PROVIDER_ROOT

stack_files=(-c "$PROVIDER_ROOT/templates/tenant-stack.yml")
[[ "$SHARED_DB" != true ]] && stack_files+=(-c "$PROVIDER_ROOT/templates/tenant-db-dedicated.yml")

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: docker stack deploy ${stack_files[*]} $STACK_NAME (shared-db=$SHARED_DB)"
  exit 0
fi

docker stack deploy --with-registry-auth "${stack_files[@]}" "$STACK_NAME"
log "Tenant stack deploy submitted: $STACK_NAME (shared-db=$SHARED_DB)"

if [[ "$SKIP_MIGRATE" != true ]]; then
  log "Waiting before migration job"
  sleep 30
  # shared DB lives on kutab-shared; a dedicated DB on the tenant overlay
  migrate_net="${STACK_NAME}_tenant-internal"
  [[ "$SHARED_DB" == true ]] && migrate_net="kutab-shared"
  docker run --rm \
    --network "$migrate_net" \
    --env-file "$TENANT_DIR/backend.env" \
    -e CONTAINER_MODE=cli \
    "$BACKEND_IMAGE" \
    sh -lc 'php artisan migrate --force && php artisan db:seed --force'
fi

node_state_set PROVIDER swarm
node_state_append TENANTS "$TENANT_NAME"
log "Tenant deployment is ready to verify"
