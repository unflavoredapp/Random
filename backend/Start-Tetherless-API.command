#!/bin/zsh
# Brand: Tetherless · https://tetherless.dev
# Prefer WebSSH: zsh ~/tetherless/server/mac-ssh.sh api
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/bin:/users/client/bin:$PATH"

for f in "$HOME/.tetherless-mac.env" /users/client/.tetherless-mac.env; do
  [[ -f "$f" ]] && source "$f" && break
done

REPO=""
for d in "$HOME/tetherless" /users/client/tetherless; do
  [[ -f "$d/server/mac-ssh.sh" ]] && REPO="$d" && break
done
[[ -n "$REPO" ]] || { echo "Missing tetherless repo"; read -k1; exit 1; }

echo "Starting Mac HTTPS API + tunnel (same as: zsh ~/tetherless/server/mac-ssh.sh api)…"
zsh "$REPO/server/mac-ssh.sh" api
echo
echo "Leave this window open. Paste the Mac API URL into iOS → FairPlay Decrypt → Save Mac API."
echo "Press any key to stop the API + tunnel…"
read -k1
zsh "$REPO/server/mac-ssh.sh" stop-api
