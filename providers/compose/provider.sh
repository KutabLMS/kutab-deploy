#!/usr/bin/env bash
# Compose provider — one dedicated box per client, no Swarm. Scaling is just
# `docker compose up --scale` behind the bundled Traefik. Best for a single
# client node where Swarm orchestration is overkill.
PROVIDER_NAME="compose"
PROVIDER_DESC="Docker Compose — dedicated single box per client (simple scaling)"

provider_actions() {
  cat <<'ACT'
Deploy edge (Traefik + shared DB)
Deploy a tenant
Scale services
Update deployment
Set custom domain
Set TLS / cert mode
WhatsApp gateway
Host database (optional)
Status
ACT
}

_compose_projects() { ls -1 "$(provider_state_root compose)/envs" 2>/dev/null | grep -v '^_edge$' || true; }
_compose_pick() {
  local opts; mapfile -t opts < <(_compose_projects)
  (( ${#opts[@]} )) || { ui_warn 'No compose deployments yet.'; return 1; }
  ui_menu 'Which deployment?' "${opts[@]}"
}

provider_flow() {
  local S="$PROVIDER_SCRIPTS"
  case "$1" in
    'Deploy edge'*)
      local email tls=(--tls-mode le) sdb=()
      email="$(ui_input "ACME / Let's Encrypt email")"
      if ui_confirm 'Are the domains on this host proxied through Cloudflare (orange cloud)?'; then
        tls=(--tls-mode cloudflare)
        ui_note 'Origin serves a self-signed cert — set each domain Cloudflare SSL/TLS to "Full". No token needed.'
      fi
      ui_confirm 'Also run a SHARED MySQL here (tenants can use --db-mode shared)?' && sdb=(--shared-db)
      bash "$S/deploy-edge.sh" --acme-email "$email" "${tls[@]}" "${sdb[@]}"
      ;;
    'Deploy a tenant')
      ghcr_login_flow || return
      local name domain custom email wa=() chan db
      name="$(ui_input 'Name (slug)')"; require_slug "$name"
      domain="$(ui_input 'Tenant domain (e.g. acme.com)')"
      custom="$(ui_input 'Extra/custom domain (optional)')"
      email="$(ui_input "ACME / Let's Encrypt email")"
      chan="$(ui_menu 'Which build channel?' 'latest — stable (master)' 'dev — development branch')" || return
      case "$chan" in dev*) chan=dev ;; *) chan=latest ;; esac
      db="$(ui_menu 'Database for this tenant' 'bundled — its own MySQL container' 'shared — the edge MySQL (kutab-db)' 'host — MariaDB installed on the host')" || return
      case "$db" in shared*) db=shared ;; host*) db=host ;; *) db=bundled ;; esac
      ui_confirm 'Also run the WhatsApp gateway for this tenant?' && wa=(--with-whatsapp)
      # shellcheck disable=SC2086
      bash "$S/deploy.sh" "$name" --tenant-domain "$domain" --acme-email "$email" \
        --channel "$chan" --db-mode "$db" ${custom:+--custom-domain "$custom"} "${wa[@]}"
      show_dns "$domain" "$custom" "$(public_ip)"
      ;;
    'Scale services')
      local name be hz; name="$(_compose_pick)" || return
      be="$(ui_input 'backend (php-fpm) replicas' '2')"; hz="$(ui_input 'horizon (queue) replicas' '1')"
      bash "$S/scale.sh" "$name" --backend "$be" --horizon "$hz"
      ;;
    'Update deployment')
      local name; name="$(_compose_pick)" || return
      bash "$S/update.sh" "$name"
      ;;
    'Set custom domain')
      local name d; name="$(_compose_pick)" || return
      d="$(ui_input 'Custom domain to add (leave blank to remove the current one)')"
      if [[ -n "$d" ]]; then bash "$S/set-domain.sh" "$name" --custom-domain "$d"; show_dns "$d" "" "$(public_ip)"
      else bash "$S/set-domain.sh" "$name" --remove; fi
      ;;
    'Set TLS / cert mode')
      # Traefik is host-level (shared edge) — this applies to every tenant here.
      local m tok=()
      m="$(ui_menu 'Certificate mode (whole host)' 'cloudflare — behind Cloudflare proxy (self-signed origin)' 'le — direct domains, Lets Encrypt HTTP-01' 'le-dns-cloudflare — LE DNS-01 (needs token)')" || return
      case "$m" in
        cloudflare*) m=cloudflare ;;
        le-dns*) m=le-dns-cloudflare; tok=(--cf-dns-token "$(ui_input 'Cloudflare API token (Zone:DNS:Edit + Zone:Read)')") ;;
        le*) m=le ;;
        *) return ;;
      esac
      bash "$S/set-tls.sh" --tls-mode "$m" "${tok[@]}"
      ;;
    'WhatsApp gateway')
      local name; name="$(_compose_pick)" || return
      bash "$S/whatsapp.sh" "$name"
      ;;
    'Host database'*) bash "$S/setup-db.sh" ;;
    Status)
      ui_title 'Compose deployments'
      local p; for p in $(_compose_projects); do printf '  • %s\n' "$p"; done
      [[ -z "$(_compose_projects)" ]] && ui_note 'none yet'
      ;;
  esac
}
