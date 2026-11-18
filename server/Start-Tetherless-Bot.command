#!/bin/zsh
# Brand: Tetherless · https://tetherless.dev
# Double-click on the Mac desktop (GUI session) so ipatool Keychain works.
set -euo pipefail

export PATH="/opt/homebrew/bin:$HOME/bin:/users/client/bin:$PATH"

# Prefer lowercase home on case-sensitive MacDuty volumes
ENV_FILE=""
for f in "$HOME/.tetherless-mac.env" /users/client/.tetherless-mac.env; do
  [[ -f "$f" ]] && ENV_FILE="$f" && break
done
if [[ -n "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

REPO=""
for d in "$HOME/tetherless" /users/client/tetherless; do
  [[ -f "$d/server/mac-tg-bot.js" ]] && REPO="$d" && break
done
if [[ -z "$REPO" ]]; then
  echo "Missing tetherless repo (server/mac-tg-bot.js)."
  read -k 1 "?Press any key…"
  exit 1
fi

# Auto-unlock dedicated keychain if password is in env
if [[ -n "${TETHERLESS_KEYCHAIN_PASSWORD:-}" ]]; then
  KC="$HOME/Library/Keychains/tetherless.keychain-db"
  if [[ -f "$KC" ]]; then
    security unlock-keychain -p "$TETHERLESS_KEYCHAIN_PASSWORD" "$KC" 2>/dev/null || true
    security list-keychains -d user -s "$KC" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
  else
    zsh "$REPO/server/mac-keychain-setup.sh" || true
  fi
fi

cd "$REPO"
exec node server/mac-tg-bot.js
