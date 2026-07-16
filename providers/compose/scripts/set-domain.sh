#!/usr/bin/env bash
# Add / change / remove the custom domain on a running compose single-box
# deployment. Rebuilds CUSTOM_DOMAIN + FRONTEND_HOST_RULE in the deployment's
# .env and re-applies so Traefik picks up the new Host(...) rule and requests a
# certificate for it.
#   set-domain.sh <name> --custom-domain <d>
#   set-domain.sh <name> --remove
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

NAME="${1:?usage: set-domain.sh <name> --custom-domain <d> | --remove}"; shift
NEW_CUSTOM=""; REMOVE=false
while [[ $# -gt 0 ]]; do case "$1" in
  --custom-domain) NEW_CUSTOM="$2"; shift 2 ;;
  --remove) REMOVE=true; shift ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) fail "Unknown option: $1" ;;
esac; done
[[ "$REMOVE" == true || -n "$NEW_CUSTOM" ]] || fail "Pass --custom-domain <d> or --remove"
[[ "$REMOVE" == true ]] && NEW_CUSTOM=""

DIR="$DATA_ROOT/envs/$NAME"; ENVF="$DIR/.env"
[[ -f "$ENVF" ]] || fail "No compose deployment '$NAME' at $DIR"
require_docker

TENANT_DOMAIN="$(grep -E '^TENANT_DOMAIN=' "$ENVF" | cut -d= -f2-)"
[[ -n "$TENANT_DOMAIN" ]] || fail "TENANT_DOMAIN missing from $ENVF — re-deploy once to record it."

# Traefik rule is rebuilt from scratch each time so it never accumulates stale hosts.
host_rule() { local r="" h; for h in "$@"; do [[ -n "$h" ]] || continue; [[ -z "$r" ]] && r="Host(\`$h\`)" || r="$r || Host(\`$h\`)"; done; printf '%s' "$r"; }
NEW_RULE="$(host_rule "$TENANT_DOMAIN" "$NEW_CUSTOM")"

# upsert KEY=VALUE in .env (value may contain spaces / backticks / pipes → awk, not sed)
upsert() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$ENVF"; then
    awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' "$ENVF" > "$ENVF.tmp" && mv "$ENVF.tmp" "$ENVF"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENVF"
  fi
}
upsert CUSTOM_DOMAIN "$NEW_CUSTOM"
upsert FRONTEND_HOST_RULE "$NEW_RULE"
chmod 600 "$ENVF"

COMPOSE="$PROVIDER_ROOT/templates/single-stack.compose.yml"
compose=(docker compose -p "kutab-$NAME" --env-file "$ENVF" -f "$COMPOSE")
log "Re-applying frontend routing for $NAME (custom domain: ${NEW_CUSTOM:-<none>})"
"${compose[@]}" up -d frontend   # Traefik lives on the shared edge; it re-reads labels itself

if [[ -n "$NEW_CUSTOM" ]]; then
  ok "Custom domain set to $NEW_CUSTOM. Point its DNS A record at this host — Traefik fetches the cert on first hit."
else
  ok "Custom domain removed from $NAME (now serving $TENANT_DOMAIN only)."
fi
