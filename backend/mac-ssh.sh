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
#   zsh ~/tetherless/server/mac-ssh.sh login     # keychain + ipatool auth login
#
set -euo pipefail

# SSH shells often miss Homebrew / go / local bins — keep ipatool reachable.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/bin:$HOME/go/bin:$HOME/.local/bin:/users/client/bin:/users/client/go/bin:/usr/local/bin:/usr/local/go/bin:$PATH"

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
DISCORD_PID="$RUN_DIR/discord.pid"
DISCORD_LOG="$RUN_DIR/discord.log"
API_PID="$RUN_DIR/api.pid"
API_LOG="$RUN_DIR/api.log"
CF_PID="$RUN_DIR/cloudflared.pid"
CF_LOG="$RUN_DIR/cloudflared.log"

# Resolve ipatool even when interactive SSH PATH is bare.
resolve_ipatool() {
  local c
  c="$(command -v ipatool 2>/dev/null || true)"
  if [[ -n "$c" && -x "$c" ]]; then
    echo "$c"
    return 0
  fi
  local cand
  for cand in \
    "${FAIRPLAY_IPATOOL_BIN:-}" \
    /opt/homebrew/bin/ipatool \
    /usr/local/bin/ipatool \
    "$HOME/bin/ipatool" \
    "$HOME/go/bin/ipatool" \
    "$HOME/.local/bin/ipatool" \
    /users/client/bin/ipatool \
    /users/client/go/bin/ipatool
  do
    [[ -n "$cand" && -x "$cand" ]] || continue
    echo "$cand"
    return 0
  done
  return 1
}

unlock_keychain() {
  local pass="${TETHERLESS_KEYCHAIN_PASSWORD:-}"
  local kc="$HOME/Library/Keychains/tetherless.keychain-db"
  if [[ -z "$pass" ]]; then
    echo "WARN: TETHERLESS_KEYCHAIN_PASSWORD not set in ${ENV_FILE:-~/.tetherless-mac.env}"
    echo "  Add a line, then re-run unlock/login:"
    echo "    TETHERLESS_KEYCHAIN_PASSWORD='pick-a-strong-pass'"
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
  local bin
  if bin="$(resolve_ipatool)"; then
    echo "ipatool: $bin"
    "$bin" auth info 2>&1 | head -5 || true
    if ! "$bin" auth info >/dev/null 2>&1; then
      echo "not logged in — run: zsh $REPO/server/mac-ssh.sh login"
    fi
  else
    echo "ipatool: not found (install or set FAIRPLAY_IPATOOL_BIN in ~/.tetherless-mac.env)"
  fi
}

# Interactive App Store login over SSH (uses resolved ipatool path).
cmd_login() {
  local envf="${ENV_FILE:-$HOME/.tetherless-mac.env}"
  if [[ -z "${TETHERLESS_KEYCHAIN_PASSWORD:-}" ]]; then
    echo "TETHERLESS_KEYCHAIN_PASSWORD is required for SSH login."
    echo "Add to $envf (do not commit):"
    echo "  TETHERLESS_KEYCHAIN_PASSWORD='pick-a-strong-pass'"
    echo "Then: zsh $REPO/server/mac-ssh.sh login"
    exit 1
  fi
  if [[ ! -f "$HOME/Library/Keychains/tetherless.keychain-db" ]]; then
    zsh "$REPO/server/mac-keychain-setup.sh"
  else
    unlock_keychain
  fi
  local bin
  if ! bin="$(resolve_ipatool)"; then
    echo "ipatool binary not found. Install it, or set FAIRPLAY_IPATOOL_BIN=/full/path/to/ipatool"
    exit 1
  fi
  echo "Using: $bin"
  echo "Sign in with the Apple ID used for App Store downloads."
  echo "If Keychain asks for a password, use TETHERLESS_KEYCHAIN_PASSWORD → Always Allow."
  "$bin" auth login
  echo
  "$bin" auth info 2>&1 | head -8 || true
}

cmd_stop() {
  stop_pidfile "$BOT_PID" "bot"
  stop_pidfile "$DISCORD_PID" "discord"
  # Also kill stragglers from desktop launches
  pkill -f "node server/mac-tg-bot.js" 2>/dev/null || true
  pkill -f "node.*/mac-tg-bot.js" 2>/dev/null || true
  pkill -f "node server/mac-discord-bot.js" 2>/dev/null || true
  pkill -f "node.*/mac-discord-bot.js" 2>/dev/null || true
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
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && -z "${DISCORD_BOT_TOKEN:-}" ]]; then
    echo "Need TELEGRAM_BOT_TOKEN and/or DISCORD_BOT_TOKEN in $ENV_FILE"
    exit 1
  fi
  # Progress banners + Discord bot deps.
  if [[ -f server/package.json ]]; then
    if [[ ! -d server/node_modules/sharp ]] || ! node -e "require('./server/node_modules/sharp')" 2>/dev/null \
      || [[ -n "${DISCORD_BOT_TOKEN:-}" && ! -d server/node_modules/discord.js ]]; then
      echo "Installing server deps (sharp / discord.js)…"
      (cd server && npm install --omit=dev) || echo "npm install failed — check server/package.json"
    fi
  fi
  # Public HTTPS for big-IPA /d/ links (Discord + Telegram).
  if ! alive_pid "$API_PID" || ! alive_pid "$CF_PID"; then
    echo "Starting Mac API + Cloudflare for IPA downloads…"
    cmd_api
  fi
  local started=0
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    if [[ "${TELEGRAM_LOCKDOWN:-}" == "1" ]]; then
      echo "Telegram: lockdown (TELEGRAM_ALLOWED_IDS)"
    else
      echo "Telegram: public"
    fi
    nohup node server/mac-tg-bot.js >>"$BOT_LOG" 2>&1 &
    echo $! >"$BOT_PID"
    sleep 1
    if alive_pid "$BOT_PID"; then
      echo "Telegram bot pid=$(cat "$BOT_PID") · log: $BOT_LOG"
      started=1
    else
      echo "Telegram bot failed — last log lines:"
      tail -n 40 "$BOT_LOG" || true
    fi
  else
    rm -f "$BOT_PID"
    echo "Telegram: skipped (no TELEGRAM_BOT_TOKEN)"
  fi
  if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
    echo "Discord: FastDecrypt"
    : >"$DISCORD_LOG"
    nohup node server/mac-discord-bot.js >>"$DISCORD_LOG" 2>&1 &
    echo $! >"$DISCORD_PID"
    sleep 2
    if alive_pid "$DISCORD_PID"; then
      echo "Discord bot pid=$(cat "$DISCORD_PID") · log: $DISCORD_LOG"
      started=1
    else
      echo "Discord bot failed — last log lines:"
      tail -n 40 "$DISCORD_LOG" || true
    fi
  else
    rm -f "$DISCORD_PID"
  fi
  if [[ -n "${MAC_PUBLIC_BASE:-}" ]]; then
    echo "Public API: ${MAC_PUBLIC_BASE%/}/  · tg-login: ${MAC_PUBLIC_BASE%/}/tg-login"
  fi
  echo "Stop: zsh $REPO/server/mac-ssh.sh stop"
  if [[ "$started" -eq 0 ]]; then
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
  echo "=== telegram ($BOT_LOG) ==="
  tail -n "$n" "$BOT_LOG" 2>/dev/null || echo "(no telegram log yet)"
  echo
  echo "=== discord ($DISCORD_LOG) ==="
  tail -n "$n" "$DISCORD_LOG" 2>/dev/null || echo "(no discord log yet)"
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
    echo "Restarting public Mac API (Cloudflare HTTPS) for web Telegram login…"
    cmd_api
    if [[ -n "${MAC_PUBLIC_BASE:-}" ]]; then
      echo
      echo ">>> On iPhone Safari open (decrypt.team-style login):"
      echo ">>>   ${MAC_PUBLIC_BASE%/}/tg-login"
      echo
    else
      echo "WARN: tunnel URL missing — check: tail -f $CF_LOG"
    fi
    echo "CLI phone-code instead: zsh $REPO/server/mac-ssh.sh session --code"
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
    echo "telegram: running pid $(cat "$BOT_PID")"
  else
    echo "telegram: stopped"
  fi
  if alive_pid "$DISCORD_PID"; then
    echo "discord:  running pid $(cat "$DISCORD_PID")"
  else
    echo "discord:  stopped${DISCORD_BOT_TOKEN:+ (token set — try start)}"
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
  local ibin
  if ibin="$(resolve_ipatool)"; then
    echo -n "ipatool: $ibin · "
    local info
    info="$("$ibin" auth info 2>&1 || true)"
    if echo "$info" | grep -qiE 'email|logged|name@|@[a-z0-9.-]+\.[a-z]'; then
      echo "$info" | head -3
    elif [[ -z "$info" ]]; then
      echo "not logged in — run: zsh $REPO/server/mac-ssh.sh login"
    else
      echo "$info" | head -2
    fi
  else
    echo "ipatool: missing — set FAIRPLAY_IPATOOL_BIN or install into PATH"
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
  zsh $REPO/server/mac-ssh.sh login    # App Store / ipatool (finds binary off PATH)
  zsh $REPO/server/mac-ssh.sh pull

Requires $HOME/.tetherless-mac.env with TELEGRAM_BOT_TOKEN and/or DISCORD_BOT_TOKEN
plus TETHERLESS_KEYCHAIN_PASSWORD (dedicated keychain — works over SSH).
Discord: rename app to FastDecrypt, enable Message Content Intent, invite bot.
Never commit bot tokens — put them only in ~/.tetherless-mac.env on the Mac.
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
  login|auth) cmd_login ;;
  pull) cmd_pull ;;
  -h|--help|help|"") usage ;;
  *) echo "Unknown: $cmd"; usage; exit 1 ;;
esac
