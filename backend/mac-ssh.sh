#!/bin/zsh
# Brand: Tetherless · https://tetherless.dev
#
# Run everything from WebSSH / plain SSH — no Mac desktop required
# (uses tetherless.keychain-db + TETHERLESS_KEYCHAIN_PASSWORD).
#
#   zsh ~/tetherless/server/mac-ssh.sh start     # bot in background
#   zsh ~/tetherless/server/mac-ssh.sh stop
#   zsh ~/tetherless/server/mac-ssh.sh status
#   zsh ~/tetherless/server/mac-ssh.sh logs
#   zsh ~/tetherless/server/mac-ssh.sh api       # HTTPS backup API + cloudflared
#   zsh ~/tetherless/server/mac-ssh.sh pull
#   zsh ~/tetherless/server/mac-ssh.sh unlock    # keychain only
#
set -euo pipefail

export PATH="/opt/homebrew/bin:$HOME/bin:/users/client/bin:/usr/local/bin:$PATH"

ENV_FILE=""
for f in "$HOME/.tetherless-mac.env" /users/client/.tetherless-mac.env; do
  [[ -f "$f" ]] && ENV_FILE="$f" && break
done
if [[ -n "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

REPO=""
for d in "$HOME/tetherless" /users/client/tetherless; do
  [[ -f "$d/server/mac-tg-bot.js" ]] && REPO="$d" && break
done
if [[ -z "$REPO" ]]; then
  echo "Missing ~/tetherless (server/mac-tg-bot.js). Clone first."
  exit 1
fi

RUN_DIR="${MAC_SSH_RUN_DIR:-$HOME/tetherless-run}"
mkdir -p "$RUN_DIR"
BOT_PID="$RUN_DIR/bot.pid"
BOT_LOG="$RUN_DIR/bot.log"
API_PID="$RUN_DIR/api.pid"
API_LOG="$RUN_DIR/api.log"
CF_PID="$RUN_DIR/cloudflared.pid"
CF_LOG="$RUN_DIR/cloudflared.log"

unlock_keychain() {
  local pass="${TETHERLESS_KEYCHAIN_PASSWORD:-}"
  local kc="$HOME/Library/Keychains/tetherless.keychain-db"
  if [[ -z "$pass" ]]; then
    echo "WARN: TETHERLESS_KEYCHAIN_PASSWORD not set in $ENV_FILE — ipatool may fail over SSH."
    return 0
  fi
  if [[ ! -f "$kc" ]]; then
    echo "Creating dedicated keychain…"
    zsh "$REPO/server/mac-keychain-setup.sh"
  else
    security unlock-keychain -p "$pass" "$kc"
    security list-keychains -d user -s "$kc" 2>/dev/null || true
    security default-keychain -d user -s "$kc" 2>/dev/null || true
    security set-keychain-settings -t 21600 -l "$kc" 2>/dev/null || true
  fi
  echo "Keychain unlocked: $kc"
}

alive_pid() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local p
  p="$(cat "$f" 2>/dev/null || true)"
  [[ -n "$p" ]] || return 1
  kill -0 "$p" 2>/dev/null
}

stop_pidfile() {
  local f="$1"
  local name="$2"
  if alive_pid "$f"; then
    local p
    p="$(cat "$f")"
    kill "$p" 2>/dev/null || true
    sleep 0.5
    kill -9 "$p" 2>/dev/null || true
    echo "Stopped $name (pid $p)"
  else
    echo "$name not running"
  fi
  rm -f "$f"
}

cmd_pull() {
  cd "$REPO"
  # Always land on origin/main so banner/bot fixes actually ship (feature
  # branches left checked out kept serving the old pill progress card).
  git fetch origin main 2>/dev/null || git fetch origin 2>/dev/null || true
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  if [[ "$branch" != "main" ]]; then
    echo "Switching $branch → main (progress card / bot updates live on main)"
    git checkout main 2>/dev/null || git checkout -B main origin/main
  fi
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    git merge --ff-only origin/main 2>/dev/null || git reset --hard origin/main
  elif git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    git pull --ff-only
  else
    git pull origin main || true
  fi
  echo "Repo: $REPO @ $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
  if grep -q 'homescreenOverlaySvg' server/mac-tg-progress-banner.js 2>/dev/null; then
    echo "Banner: homescreen-circle"
  else
    echo "WARN: banner still legacy — check git remote / pull"
  fi
}

cmd_unlock() {
  unlock_keychain
  if command -v ipatool >/dev/null 2>&1; then
    ipatool auth info 2>&1 | head -5 || echo "ipatool not logged in — from SSH run: ipatool auth login"
  fi
}

cmd_stop() {
  stop_pidfile "$BOT_PID" "bot"
  # Also kill stragglers from desktop launches
  pkill -f "node server/mac-tg-bot.js" 2>/dev/null || true
  pkill -f "node.*/mac-tg-bot.js" 2>/dev/null || true
}

cmd_stop_api() {
  stop_pidfile "$CF_PID" "cloudflared"
  stop_pidfile "$API_PID" "api"
  pkill -f "node server/mac-https-api.js" 2>/dev/null || true
  pkill -f "cloudflared tunnel" 2>/dev/null || true
}

cmd_start() {
  cmd_pull
  unlock_keychain
  cmd_stop
  cd "$REPO"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    echo "TELEGRAM_BOT_TOKEN missing in $ENV_FILE"
    exit 1
  fi
  # Progress banners need sharp (Home Screen circle card). Install if missing.
  if [[ -f server/package.json ]]; then
    if [[ ! -d server/node_modules/sharp ]] || ! node -e "require('./server/node_modules/sharp')" 2>/dev/null; then
      echo "Installing server deps (sharp)…"
      (cd server && npm install --omit=dev) || echo "npm install failed — banners will fall back to prior card"
    fi
  fi
  # Public by default — lockdown only when TELEGRAM_LOCKDOWN=1.
  if [[ "${TELEGRAM_LOCKDOWN:-}" == "1" ]]; then
    echo "Access: lockdown (TELEGRAM_ALLOWED_IDS)"
  else
    echo "Access: public (anyone who messages)"
  fi
  nohup node server/mac-tg-bot.js >>"$BOT_LOG" 2>&1 &
  echo $! >"$BOT_PID"
  sleep 1
  if alive_pid "$BOT_PID"; then
    echo "Bot started (pid $(cat "$BOT_PID")) · workers=${MAC_TG_WORKERS:-3}"
    echo "Logs: tail -f $BOT_LOG"
    echo "Stop: zsh $REPO/server/mac-ssh.sh stop"
    # Confirm the running tree has the circle banner (not the old pill card).
    grep -q 'homescreenOverlaySvg' "$REPO/server/mac-tg-progress-banner.js" 2>/dev/null \
      && echo "Banner: homescreen-circle OK" \
      || echo "WARN: banner file looks legacy — pull may have failed"
  else
    echo "Bot failed to stay up — last log lines:"
    tail -n 40 "$BOT_LOG" || true
    exit 1
  fi
}

# Persist live Mac HTTPS API public URL (trycloudflare) for the iOS Decrypt site URL + bot /d/ links.
write_mac_public_base() {
  local url="${1:-}"
  [[ -n "$url" ]] || return 1
  url="${url%/}"
  mkdir -p "$RUN_DIR"
  printf '%s\n' "$url" >"$RUN_DIR/mac-public-url"
  printf '%s\n' "$url" >"$HOME/.tetherless-mac-public-url"
  export MAC_PUBLIC_BASE="$url"
  local envf="${ENV_FILE:-$HOME/.tetherless-mac.env}"
  mkdir -p "$(dirname "$envf")"
  if [[ -f "$envf" ]]; then
    if grep -q '^MAC_PUBLIC_BASE=' "$envf" 2>/dev/null; then
      # Avoid sed -i portability issues on macOS.
      local tmp
      tmp="$(mktemp)"
      awk -v u="$url" '
        BEGIN { done=0 }
        /^MAC_PUBLIC_BASE=/ { print "MAC_PUBLIC_BASE=" u; done=1; next }
        { print }
        END { if (!done) print "MAC_PUBLIC_BASE=" u }
      ' "$envf" >"$tmp" && mv "$tmp" "$envf"
    else
      printf '\nMAC_PUBLIC_BASE=%s\n' "$url" >>"$envf"
    fi
  else
    printf 'MAC_PUBLIC_BASE=%s\n' "$url" >"$envf"
    ENV_FILE="$envf"
  fi
  echo "Mac API (iOS Decrypt site URL): ${url}/"
}

wait_for_tunnel_url() {
  local i url=""
  for i in {1..20}; do
    url="$(grep -Eo 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -1 || true)"
    if [[ -n "$url" ]]; then
      write_mac_public_base "$url"
      return 0
    fi
    sleep 1
  done
  return 1
}

cmd_api() {
  unlock_keychain
  cmd_stop_api
  cd "$REPO"
  export MAC_API_OPEN="${MAC_API_OPEN:-1}"
  export MAC_API_PORT="${MAC_API_PORT:-8787}"

  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "Installing cloudflared…"
    mkdir -p "$HOME/bin"
    curl -fsSL -o /tmp/cloudflared.tgz \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz"
    tar -xzf /tmp/cloudflared.tgz -C "$HOME/bin"
    if [[ ! -x "$HOME/bin/cloudflared" ]]; then
      local cf
      cf="$(find "$HOME/bin" -maxdepth 1 -type f -name 'cloudflared*' | head -1)"
      [[ -n "$cf" ]] && ln -sfn "$cf" "$HOME/bin/cloudflared"
    fi
    chmod +x "$HOME/bin/cloudflared" 2>/dev/null || true
  fi

  : >"$CF_LOG"
  nohup node server/mac-https-api.js >>"$API_LOG" 2>&1 &
  echo $! >"$API_PID"
  sleep 1
  nohup cloudflared tunnel --url "http://127.0.0.1:${MAC_API_PORT}" >>"$CF_LOG" 2>&1 &
  echo $! >"$CF_PID"
  echo "API pid=$(cat "$API_PID" 2>/dev/null) cloudflared pid=$(cat "$CF_PID" 2>/dev/null)"
  if wait_for_tunnel_url; then
    echo "Paste that URL into iOS → Account → FairPlay Decrypt → Mac API URL → Save."
  else
    echo "Tunnel URL not ready yet — watch: tail -f $CF_LOG"
    echo "When https://….trycloudflare.com appears, paste it as the iOS Mac API URL."
  fi
}

cmd_logs() {
  local n="${1:-80}"
  echo "=== bot ($BOT_LOG) ==="
  tail -n "$n" "$BOT_LOG" 2>/dev/null || echo "(no bot log yet)"
}

cmd_session() {
  local py_args=()
  local invite=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --code|code|-c) py_args+=(--code); shift ;;
      *) invite="$1"; shift ;;
    esac
  done
  echo "Installing pyrogram (Premium user uploads ≤4 GB)…"
  python3 -m pip install --user -q pyrogram tgcrypto
  echo
  if (( ${#py_args[@]} )); then
    echo "Phone + login-code mode (flaky — prefer HTTPS /tg-login)."
  else
    # Always restart API so /tg-login from latest pull is loaded (old process → Not found).
    echo "Restarting public Mac API (Cloudflare HTTPS) for /tg-login…"
    cmd_api
    if [[ -n "${MAC_PUBLIC_BASE:-}" ]]; then
      echo
      echo ">>> On iPhone Safari open EXACTLY:"
      echo ">>>   ${MAC_PUBLIC_BASE%/}/tg-login"
      echo
    else
      echo "WARN: tunnel URL missing — check: tail -f $CF_LOG"
    fi
    echo "Phone-code instead: zsh $REPO/server/mac-ssh.sh session --code"
  fi
  if [[ -z "${TELEGRAM_API_ID:-}" || -z "${TELEGRAM_API_HASH:-}" ]]; then
    echo "Tip: set TELEGRAM_API_ID / TELEGRAM_API_HASH in ~/.tetherless-mac.env first."
  fi
  # Reload env so Python sees MAC_PUBLIC_BASE from cmd_api.
  if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
  python3 "$REPO/server/mac-tg-session-setup.py" "${py_args[@]}"
  # Reload env so channel step sees the fresh TELEGRAM_SESSION.
  if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
  if [[ -n "$invite" ]]; then
    echo
    echo "Wiring staging channel from invite…"
    cmd_channel "$invite"
    return
  fi
  echo
  echo "Next (large IPAs):"
  echo "  zsh $REPO/server/mac-ssh.sh channel 'https://t.me/+YOUR_INVITE'"
  echo "  (then make @${TELEGRAM_BOT_USERNAME:-FastDecryptAI} a channel admin — Post messages)"
  echo
  echo "Restarting bot so it uses your Premium session…"
  cmd_start
}

cmd_channel() {
  local invite="${1:-}"
  if [[ -z "$invite" ]]; then
    echo "Usage: zsh $REPO/server/mac-ssh.sh channel 'https://t.me/+….…'"
    exit 1
  fi
  if [[ -z "${TELEGRAM_SESSION:-}${TELEGRAM_SESSION_STRING:-}" || -z "${TELEGRAM_API_ID:-}" ]]; then
    echo "Premium session missing. Log in first (optionally pass this invite):"
    echo "  zsh $REPO/server/mac-ssh.sh session '$invite'"
    exit 1
  fi
  python3 -m pip install --user -q pyrogram tgcrypto
  python3 "$REPO/server/mac-tg-channel-setup.py" "$invite"
  echo
  echo "Restarting bot with TELEGRAM_UPLOAD_CHANNEL…"
  cmd_start
}

cmd_status() {
  echo "repo:   $REPO"
  echo "env:    ${ENV_FILE:-none}"
  if alive_pid "$BOT_PID"; then
    echo "bot:    running pid $(cat "$BOT_PID")"
  else
    echo "bot:    stopped"
  fi
  if [[ -n "${TELEGRAM_SESSION:-}${TELEGRAM_SESSION_STRING:-}" && -n "${TELEGRAM_API_ID:-}" ]]; then
    local flag="${TELEGRAM_PREMIUM_UPLOAD:-1}"
    if [[ "$flag" == "0" || "$flag" == "false" || "$flag" == "off" ]]; then
      echo "upload: Premium session present but disabled (TELEGRAM_PREMIUM_UPLOAD=$flag)"
    else
      echo "upload: Premium user session (≤4 GB)"
    fi
    if [[ -n "${TELEGRAM_UPLOAD_CHANNEL:-}${TELEGRAM_PREMIUM_CHANNEL:-}" ]]; then
      echo "channel: ${TELEGRAM_UPLOAD_CHANNEL:-$TELEGRAM_PREMIUM_CHANNEL}"
    else
      echo "channel: unset — add TELEGRAM_UPLOAD_CHANNEL=-100… (private channel, bot admin)"
    fi
  else
    echo "upload: Bot API only — session missing. Run: zsh $REPO/server/mac-ssh.sh session 'https://t.me/+YOUR_INVITE'"
  fi
  if alive_pid "$API_PID"; then
    echo "api:    running pid $(cat "$API_PID") :${MAC_API_PORT:-8787}"
  else
    echo "api:    stopped"
  fi
  if alive_pid "$CF_PID"; then
    echo "tunnel: running pid $(cat "$CF_PID")"
    local tun=""
    tun="$(grep -Eo 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -1 || true)"
    if [[ -n "$tun" ]]; then
      echo "Mac API: $tun/"
      # Keep env + sidecar in sync so iOS / bot always see the live host.
      write_mac_public_base "$tun" >/dev/null || true
    fi
  else
    echo "tunnel: stopped — start Mac API: zsh $REPO/server/mac-ssh.sh api"
  fi
  if [[ -n "${MAC_PUBLIC_BASE:-}" ]]; then
    echo "public: $MAC_PUBLIC_BASE"
  elif [[ -f "$RUN_DIR/mac-public-url" ]]; then
    echo "public: $(cat "$RUN_DIR/mac-public-url" 2>/dev/null)"
  elif [[ -f "$HOME/.tetherless-mac-public-url" ]]; then
    echo "public: $(cat "$HOME/.tetherless-mac-public-url" 2>/dev/null)"
  fi
  if command -v ipatool >/dev/null 2>&1; then
    echo -n "ipatool: "
    # Prefer JSON-ish / email line from auth info; fall back to first two lines.
    local info
    info="$(ipatool auth info 2>&1 || true)"
    if echo "$info" | grep -qiE 'email|logged|name@|@[a-z0-9.-]+\.[a-z]'; then
      echo "$info" | head -3
    elif [[ -z "$info" ]]; then
      echo "not logged in — run: ipatool auth login"
    else
      echo "$info" | head -2
    fi
  else
    echo "ipatool: missing on PATH"
  fi
  if [[ -f "$REPO/server/fairplayBackends.js" ]]; then
    node -e '
      const f=require("./server/fairplayBackends");
      const st=f.backendStatus();
      const r=f.hostResources();
      console.log("unfairplay: "+(st.unfairplay&&st.unfairplay.ready?"ready":"not ready")+" · host="+st.host);
      console.log("workers: suggested "+f.suggestedWorkers(3)+" (MAC_TG_WORKERS overrides)");
      console.log("disk:    "+r.freeDiskGb.toFixed(1)+" GB free / "+(r.totalDisk/(1024**3)).toFixed(0)+" GB");
      console.log("ram:     "+r.freeMemGb.toFixed(1)+" GB free / "+r.totalMemGb.toFixed(0)+" GB");
    ' 2>/dev/null || echo "unfairplay: (status unavailable)"
  fi
  if [[ -f "$REPO/server/mac-tg-ipa-cache.js" ]]; then
    node -e "const c=require('./server/mac-tg-ipa-cache'); console.log('cache:  '+c.list().length+' IPA(s) in '+c.CACHE_DIR)" 2>/dev/null \
      || echo "cache:  (unavailable)"
  fi
}

usage() {
  cat <<EOF
Tetherless Mac SSH helper (no desktop)

  zsh $REPO/server/mac-ssh.sh start
  zsh $REPO/server/mac-ssh.sh stop
  zsh $REPO/server/mac-ssh.sh status
  zsh $REPO/server/mac-ssh.sh logs
  zsh $REPO/server/mac-ssh.sh session   # Premium login via https://…/tg-login (cellular OK)
  zsh $REPO/server/mac-ssh.sh session 'https://t.me/+…'  # login + wire staging channel
  zsh $REPO/server/mac-ssh.sh channel 'https://t.me/+…'  # secret staging channel (session already set)
  zsh $REPO/server/mac-ssh.sh api
  zsh $REPO/server/mac-ssh.sh stop-api
  zsh $REPO/server/mac-ssh.sh unlock
  zsh $REPO/server/mac-ssh.sh pull

Requires $HOME/.tetherless-mac.env with TELEGRAM_BOT_TOKEN and
TETHERLESS_KEYCHAIN_PASSWORD (dedicated keychain — works over SSH).
Premium uploads need TELEGRAM_API_ID / HASH / SESSION (mac-ssh.sh session).
Big IPAs also need TELEGRAM_UPLOAD_CHANNEL (mac-ssh.sh channel <invite>).
EOF
}

cmd="${1:-}"
case "$cmd" in
  start|bot) cmd_start ;;
  stop) cmd_stop ;;
  stop-api) cmd_stop_api ;;
  status) cmd_status ;;
  logs) shift || true; cmd_logs "${1:-80}" ;;
  session) shift || true; cmd_session "$@" ;;
  channel) shift || true; cmd_channel "${1:-}" ;;
  api) cmd_api ;;
  unlock) cmd_unlock ;;
  pull) cmd_pull ;;
  -h|--help|help|"") usage ;;
  *) echo "Unknown: $cmd"; usage; exit 1 ;;
esac
