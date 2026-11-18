#!/bin/zsh
# Brand: Tetherless · https://tetherless.dev
# Create/unlock a dedicated Keychain for ipatool so the login Keychain
# password prompt stops blocking MacDuty desktop sessions.
#
# macOS cannot "always allow regardless of password" on a locked login
# Keychain whose password you don't know. This script uses a NEW keychain
# whose password YOU set (env or prompt once).
#
# Usage (WebSSH / SSH — no desktop needed once dedicated keychain exists):
#   export TETHERLESS_KEYCHAIN_PASSWORD='pick-a-strong-pass'
#   zsh ~/tetherless/server/mac-keychain-setup.sh
#   ipatool auth login          # use THAT password if prompted → Always Allow
#   ipatool auth info
#   zsh ~/tetherless/server/mac-ssh.sh start
#
set -euo pipefail

KC_DIR="${HOME}/Library/Keychains"
KC_NAME="tetherless.keychain-db"
KC_PATH="${KC_DIR}/${KC_NAME}"
PASS="${TETHERLESS_KEYCHAIN_PASSWORD:-}"

mkdir -p "$KC_DIR"

if [[ -z "$PASS" ]]; then
  echo "Set TETHERLESS_KEYCHAIN_PASSWORD first, e.g.:"
  echo "  export TETHERLESS_KEYCHAIN_PASSWORD='YourNewPass123'"
  exit 1
fi

# Create if missing
if [[ ! -f "$KC_PATH" ]]; then
  echo "Creating $KC_PATH …"
  security create-keychain -p "$PASS" "$KC_PATH"
fi

# Prefer our keychain first (keep login in the list if it exists)
LOGIN_DB="${KC_DIR}/login.keychain-db"
LOGIN_OLD="${KC_DIR}/login.keychain"
SEARCH=("$KC_PATH")
[[ -f "$LOGIN_DB" ]] && SEARCH+=("$LOGIN_DB")
[[ -f "$LOGIN_OLD" ]] && SEARCH+=("$LOGIN_OLD")
security list-keychains -d user -s "${SEARCH[@]}"
security default-keychain -d user -s "$KC_PATH"

# Unlock + don't re-lock for a long time (6 hours)
security unlock-keychain -p "$PASS" "$KC_PATH"
security set-keychain-settings -t 21600 -l "$KC_PATH" 2>/dev/null || \
  security set-keychain-settings "$KC_PATH"

# Allow tools to read generic passwords / keys without GUI prompts when possible
security set-generic-password-partition-list -S "apple-tool:,apple:,codesign:,ipatool:" -k "$PASS" "$KC_PATH" 2>/dev/null || true
security set-key-partition-list -S "apple-tool:,apple:,codesign:,ipatool:" -s -k "$PASS" "$KC_PATH" 2>/dev/null || true

echo "OK — default keychain is $KC_PATH (unlocked)."
echo "Next: ipatool auth login"
echo "  If a padlock dialog appears, enter the SAME password you set in"
echo "  TETHERLESS_KEYCHAIN_PASSWORD, then click Always Allow."
echo
security list-keychains -d user
ipatool auth info 2>/dev/null || echo "(ipatool not signed in yet — run: ipatool auth login)"
