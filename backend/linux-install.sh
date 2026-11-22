#!/usr/bin/env bash
# Install FastDecrypt / Tetherless on Debian 13 (Trixie) with a stock iPhone Phone Worker.
# FairPlay runs on the phone (development cert + companion / worker) — no Mac, no jailbreak.
#
# Usage (as root, from repo root):
#   bash server/linux-install.sh
#   bash server/linux-install.sh --token "$(openssl rand -hex 24)"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/server"
STATE_DIR="${TETHERLESS_STATE_DIR:-/var/lib/tetherless}"
ETC_DIR="${TETHERLESS_ETC_DIR:-/etc/tetherless}"
ENV_FILE="$ETC_DIR/linux-host.env"
INSTALL_USER="${TETHERLESS_USER:-tetherless}"
WORKER_TOKEN=""
SKIP_APT=0
SKIP_NODE=0
PUBLIC_BASE=""

usage() {
  sed -n '2,9p' "$0" | sed 's/^# //;s/^#//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) WORKER_TOKEN="${2:-}"; shift 2 ;;
    --user) INSTALL_USER="${2:-}"; shift 2 ;;
    --public-base) PUBLIC_BASE="${2:-}"; shift 2 ;;
    --skip-apt) SKIP_APT=1; shift ;;
    --skip-node) SKIP_NODE=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "OS: ${PRETTY_NAME:-$ID $VERSION_ID}"
  if [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]]; then
    echo "Debian 13 detected — primary target."
  else
    echo "Note: scripts target Debian 13; continuing on ${ID:-unknown} ${VERSION_ID:-}."
  fi
fi

if [[ "$SKIP_APT" -eq 0 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl git openssl python3 \
    || true
  if ! command -v node >/dev/null 2>&1 || \
     [[ "$(node -p 'parseInt(process.versions.node,10)' 2>/dev/null || echo 0)" -lt 20 ]]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  fi
fi

if ! id -u "$INSTALL_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "/home/$INSTALL_USER" \
    --shell /usr/sbin/nologin "$INSTALL_USER"
fi

install -d -m 700 -o "$INSTALL_USER" -g "$INSTALL_USER" \
  "$STATE_DIR" \
  "$STATE_DIR/drop" \
  "$STATE_DIR/ipa-cache" \
  "$STATE_DIR/ipa-cache/encrypted" \
  "$STATE_DIR/url-log" \
  "$STATE_DIR/user-log" \
  "$STATE_DIR/run"
install -d -m 750 -o root -g "$INSTALL_USER" "$ETC_DIR"

if [[ -z "$WORKER_TOKEN" ]]; then
  WORKER_TOKEN="$(openssl rand -hex 24)"
  echo "Generated DECRYPT_WORKER_TOKEN (saved into env file)."
fi

if [[ ! -f "$ENV_FILE" ]]; then
  install -m 640 -o root -g "$INSTALL_USER" \
    "$SERVER_DIR/linux-host.env.example" "$ENV_FILE"
fi

# Patch token + host defaults into env (idempotent-ish).
tmp="$(mktemp)"
awk -v tok="$WORKER_TOKEN" -v base="$PUBLIC_BASE" '
  BEGIN { done_tok=0; done_be=0; done_host=0; done_base=0 }
  /^DECRYPT_WORKER_TOKEN=/ {
    print "DECRYPT_WORKER_TOKEN=" tok; done_tok=1; next
  }
  /^DECRYPT_BACKENDS=/ {
    print "DECRYPT_BACKENDS=phone"; done_be=1; next
  }
  /^FAIRPLAY_HOST=/ {
    print "FAIRPLAY_HOST=linux"; done_host=1; next
  }
  /^MAC_PUBLIC_BASE=/ && base != "" {
    print "MAC_PUBLIC_BASE=" base; done_base=1; next
  }
  { print }
  END {
    if (!done_tok) print "DECRYPT_WORKER_TOKEN=" tok
    if (!done_be) print "DECRYPT_BACKENDS=phone"
    if (!done_host) print "FAIRPLAY_HOST=linux"
    if (base != "" && !done_base) print "MAC_PUBLIC_BASE=" base
  }
' "$ENV_FILE" >"$tmp"
install -m 640 -o root -g "$INSTALL_USER" "$tmp" "$ENV_FILE"
rm -f "$tmp"

chmod 755 "$SERVER_DIR/linux-install.sh" "$SERVER_DIR/linux-ctl.sh" 2>/dev/null || true

if [[ "$SKIP_NODE" -eq 0 && -f "$SERVER_DIR/package.json" ]]; then
  sudo -u "$INSTALL_USER" bash -lc "cd '$SERVER_DIR' && (npm ci --omit=dev || npm install --omit=dev)"
fi

UNIT_DIR=/etc/systemd/system
for unit in tetherless-api.service tetherless-tg-bot.service tetherless-discord-bot.service; do
  if [[ -f "$SERVER_DIR/systemd/$unit" ]]; then
    sed -e "s|@SERVER_DIR@|$SERVER_DIR|g" \
        -e "s|@INSTALL_USER@|$INSTALL_USER|g" \
        -e "s|@ENV_FILE@|$ENV_FILE|g" \
        -e "s|@STATE_DIR@|$STATE_DIR|g" \
        "$SERVER_DIR/systemd/$unit" >"$UNIT_DIR/$unit"
    echo "Installed $UNIT_DIR/$unit"
  fi
done
systemctl daemon-reload

cat <<EOF

Installed Linux VPS + iPhone Phone Worker path.

  Env file:  $ENV_FILE
  Worker token (paste into TetherLess → Settings → Phone Worker):
    $WORKER_TOKEN

Next:
  1) Edit $ENV_FILE — set MAC_PUBLIC_BASE / bot tokens if needed
  2) Point DNS + Caddy at :8787 — see server/Caddyfile.linux.example
  3) systemctl enable --now tetherless-api.service
  4) On a stock iPhone (same Apple ID that owns the apps):
       • Link free/development Apple ID cert; Trust under VPN & Device Management
       • Media & Purchases signed in; leave “Server decrypt only” OFF for companion Get
       • TetherLess → FairPlay Decrypt → Decrypt site URL = your https:// host
       • Settings → Phone Worker → paste token → Enable → keep app open
  5) bash $SERVER_DIR/linux-ctl.sh status

Docs: $SERVER_DIR/fairplay-backends.md
EOF
