#!/usr/bin/env bash
# Ops helper for Debian/Linux FastDecrypt host (Phone Worker + API/bots).
# Usage:
#   bash server/linux-ctl.sh status
#   bash server/linux-ctl.sh token          # print / generate DECRYPT_WORKER_TOKEN hint
#   bash server/linux-ctl.sh api            # run mac-https-api.js in foreground
#   bash server/linux-ctl.sh tg             # run Telegram bot in foreground
#   bash server/linux-ctl.sh discord        # run Discord bot in foreground
#   bash server/linux-ctl.sh enable-api     # systemctl enable --now tetherless-api
#   bash server/linux-ctl.sh logs [api|tg|discord]
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${TETHERLESS_ENV_FILE:-/etc/tetherless/linux-host.env}"
UNIT_PREFIX=tetherless

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  elif [[ -f "$HOME/.tetherless-linux.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$HOME/.tetherless-linux.env"
    set +a
  fi
}

cmd="${1:-status}"
shift || true
load_env

case "$cmd" in
  status)
    echo "env: ${ENV_FILE}"
    echo "FAIRPLAY_HOST=${FAIRPLAY_HOST:-"(unset → linux)"}"
    echo "DECRYPT_BACKENDS=${DECRYPT_BACKENDS:-"(default phone on linux)"}"
    if [[ -n "${DECRYPT_WORKER_TOKEN:-}" ]]; then
      echo "DECRYPT_WORKER_TOKEN: set (${#DECRYPT_WORKER_TOKEN} chars)"
    else
      echo "DECRYPT_WORKER_TOKEN: MISSING — Phone Worker cannot claim jobs"
    fi
    echo "MAC_PUBLIC_BASE=${MAC_PUBLIC_BASE:-"(unset)"}"
    if command -v systemctl >/dev/null 2>&1; then
      for u in api tg-bot discord-bot; do
        unit="${UNIT_PREFIX}-${u}.service"
        if systemctl cat "$unit" >/dev/null 2>&1; then
          echo -n "$unit: "
          systemctl is-active "$unit" 2>/dev/null || true
        fi
      done
    fi
    if [[ -n "${MAC_API_PORT:-}" ]]; then
      curl -fsS "http://127.0.0.1:${MAC_API_PORT}/api/decrypt/backends" 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); fp=d.get("fairplay") or d; print("backends:", fp.get("backends") or d.get("backends")); print("phone:", (fp.get("phone") or {})); print("host:", fp.get("host") or d.get("host"))' \
        2>/dev/null || echo "API not reachable on :${MAC_API_PORT:-8787}"
    fi
    ;;
  token)
    if [[ -n "${DECRYPT_WORKER_TOKEN:-}" ]]; then
      echo "$DECRYPT_WORKER_TOKEN"
    else
      tok="$(openssl rand -hex 24)"
      echo "Generated (not saved): $tok"
      echo "Add to $ENV_FILE:"
      echo "  DECRYPT_WORKER_TOKEN=$tok"
      echo "Then paste the same value into TetherLess → Settings → Phone Worker."
    fi
    ;;
  api)
    exec env NODE_ENV="${NODE_ENV:-production}" node "$SERVER_DIR/mac-https-api.js"
    ;;
  tg|telegram)
    exec env NODE_ENV="${NODE_ENV:-production}" node "$SERVER_DIR/mac-tg-bot.js"
    ;;
  discord)
    exec env NODE_ENV="${NODE_ENV:-production}" node "$SERVER_DIR/mac-discord-bot.js"
    ;;
  enable-api)
    systemctl enable --now "${UNIT_PREFIX}-api.service"
    ;;
  enable-tg)
    systemctl enable --now "${UNIT_PREFIX}-tg-bot.service"
    ;;
  enable-discord)
    systemctl enable --now "${UNIT_PREFIX}-discord-bot.service"
    ;;
  logs)
    which="${1:-api}"
    case "$which" in
      api) unit="${UNIT_PREFIX}-api.service" ;;
      tg|telegram) unit="${UNIT_PREFIX}-tg-bot.service" ;;
      discord) unit="${UNIT_PREFIX}-discord-bot.service" ;;
      *) echo "logs [api|tg|discord]"; exit 1 ;;
    esac
    exec journalctl -u "$unit" -f -n 100
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# //;s/^#//'
    exit 1
    ;;
esac
