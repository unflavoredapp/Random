#!/bin/zsh
# Brand: Tetherless · https://tetherless.dev
# Prefer WebSSH: zsh ~/tetherless/server/mac-ssh.sh start
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/bin:/users/client/bin:$PATH"

REPO=""
for d in "$HOME/tetherless" /users/client/tetherless; do
  [[ -f "$d/server/mac-tg-bot.js" ]] && REPO="$d" && break
done
if [[ -z "$REPO" ]]; then
  echo "Missing tetherless repo"
  read -k 1 "?Press any key…"
  exit 1
fi

# Unlock dedicated keychain (same path as mac-ssh.sh)
zsh "$REPO/server/mac-ssh.sh" unlock || true

for f in "$HOME/.tetherless-mac.env" /users/client/.tetherless-mac.env; do
  [[ -f "$f" ]] && source "$f" && break
done

cd "$REPO"
exec node server/mac-tg-bot.js
