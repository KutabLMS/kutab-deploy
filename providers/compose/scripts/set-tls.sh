#!/usr/bin/env bash
# Regenerate the shared edge's traefik.env (switch the TLS / certificate strategy)
# and restart Traefik to apply it — without redeploying anything.
#
# Traefik is HOST-level (one edge serves every tenant on this box), so this is a
# host-wide setting, not per tenant.
#   set-tls.sh --tls-mode le|cloudflare|le-dns-cloudflare [--cf-dns-token <t>]
#
#   le               Let's Encrypt HTTP-01 (domains pointed directly at this box)
#   cloudflare       self-signed origin cert; set each domain's Cloudflare SSL = Full
#   le-dns-cloudflare  Let's Encrypt DNS-01 (needs --cf-dns-token for that zone)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
# shellcheck source=../../../lib/tui.sh
source "$KUTAB_ROOT/lib/tui.sh"
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

MODE=""; TOKEN=""
while [[ $# -gt 0 ]]; do case "$1" in
  --tls-mode) MODE="$2"; shift 2 ;;
  --cf-dns-token) TOKEN="$2"; shift 2 ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) fail "Unknown option: $1" ;;
esac; done
[[ -n "$MODE" ]] || fail "Pass --tls-mode le|cloudflare|le-dns-cloudflare"

DIR="$DATA_ROOT/envs/_edge"; ENVF="$DIR/.env"
[[ -f "$ENVF" ]] || fail "No edge on this host yet ($DIR). Run: kutab-deploy compose deploy-edge --acme-email <e>"
require_docker

EMAIL="$(grep -E '^ACME_EMAIL=' "$ENVF" | cut -d= -f2-)"
write_traefik_env "$DIR" "$EMAIL" "$MODE" "$TOKEN"

COMPOSE="$PROVIDER_ROOT/templates/edge-stack.compose.yml"
compose=(docker compose -p kutab-edge --env-file "$ENVF" -f "$COMPOSE")
log "Switching the edge to TLS mode '$MODE' and restarting Traefik"
"${compose[@]}" up -d traefik

[[ "$MODE" == cloudflare ]] && ui_note "Self-signed origin cert in use — set every proxied domain's Cloudflare SSL/TLS mode to \"Full\"."
ok "Edge TLS mode is now '$MODE' (traefik.env regenerated). Applies to all tenants on this host."
