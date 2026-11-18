#!/bin/zsh
# Brand: Tetherless · https://tetherless.dev
# Double-click on Mac desktop: API + Cloudflare HTTPS tunnel for iOS backup decrypt.
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/bin:/users/client/bin:$PATH"

for f in "$HOME/.tetherless-mac.env" /users/client/.tetherless-mac.env; do
  [[ -f "$f" ]] && source "$f" && break
done

REPO=""
for d in "$HOME/tetherless" /users/client/tetherless; do
  [[ -f "$d/server/mac-https-api.js" ]] && REPO="$d" && break
done
[[ -n "$REPO" ]] || { echo "Missing tetherless repo"; read -k1; exit 1; }

# Unlock dedicated keychain if configured
if [[ -n "${TETHERLESS_KEYCHAIN_PASSWORD:-}" ]]; then
  KC="$HOME/Library/Keychains/tetherless.keychain-db"
  if [[ -f "$KC" ]]; then
    security unlock-keychain -p "$TETHERLESS_KEYCHAIN_PASSWORD" "$KC" 2>/dev/null || true
    security list-keychains -d user -s "$KC" 2>/dev/null || true
  fi
fi

export MAC_API_OPEN="${MAC_API_OPEN:-1}"
export MAC_API_PORT="${MAC_API_PORT:-8787}"

# Install cloudflared if needed
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "Installing cloudflared…"
  curl -fsSL -o /tmp/cloudflared.tgz \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz"
  mkdir -p "$HOME/bin"
  tar -xzf /tmp/cloudflared.tgz -C "$HOME/bin"
  chmod +x "$HOME/bin"/cloudflared*
  # normalize name
  if [[ ! -x "$HOME/bin/cloudflared" ]]; then
    CF="$(find "$HOME/bin" -maxdepth 1 -type f -name 'cloudflared*' | head -1)"
    [[ -n "$CF" ]] && ln -sfn "$CF" "$HOME/bin/cloudflared"
  fi
fi

cd "$REPO"
echo "Starting API on :$MAC_API_PORT …"
node server/mac-https-api.js &
API_PID=$!
sleep 1
echo "Starting Cloudflare HTTPS tunnel…"
echo "Copy the https://….trycloudflare.com URL into the iOS app Decrypt site URL."
cloudflared tunnel --url "http://127.0.0.1:${MAC_API_PORT}"
kill "$API_PID" 2>/dev/null || true
