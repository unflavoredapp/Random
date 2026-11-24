#!/usr/bin/env bash
# DELvEKBot · on-device Dopamine phone worker (Telegram → VPS → clear IPA)
#
# CLI (same binary formerly known as buddy3; help uses argv[0]):
#   DELvEKBot [-v] <bundle-id-or-name|app-path|ipa-path>
#   DELvEKBot list
#   Output: /var/mobile/Documents/<bundle-id>.ipa
#
# Claim API (Random/Tetherless decrypt.js):
#   { "ok": true, "job": { "id", "url", "version" } | null }
#
# Required: bash, curl, jq, flock, sed, date, find, stat, sudo
#
set -Eeuo pipefail
umask 077

# Always elevate — FairPlay / other apps' containers need root on Dopamine.
if [[ "$(id -u)" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    printf 'DELvEKBot: ERROR: sudo is required (install sudo on Dopamine)\n' >&2
    exit 1
  fi
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SITE_URL="${DECRYPT_SITE_URL:-${MAC_PUBLIC_BASE:-}}"
TOKEN="${DECRYPT_WORKER_TOKEN:-}"
# Prefer DELvEKBot; accept legacy BUDDY3_BIN / buddy3 path.
DELVEKBOT_BIN="${DELVEKBOT_BIN:-${BUDDY3_BIN:-${SCRIPT_DIR}/DELvEKBot}}"
DOCS="${DELVEKBOT_OUT_DIR:-${BUDDY3_OUT_DIR:-/var/mobile/Documents}}"
POLL_SECONDS="${POLL_SECONDS:-3}"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-30}"
COUNTRY="${COUNTRY:-us}"
ADID="${DELVEKBOT_ADID:-${DECRYPT_WORKER_ADID:-delvekbot-dopamine}}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-15}"
CURL_MAX_TIME="${CURL_MAX_TIME:-60}"
UPLOAD_MAX_TIME="${UPLOAD_MAX_TIME:-1800}"
LOCK_FILE="${DELVEKBOT_LOCK_FILE:-${DOCS}/.delvekbot-worker.lock}"
VERBOSE="${DELVEKBOT_VERBOSE:-${BUDDY3_VERBOSE:-0}}"

BASE=""
CURRENT_JOB_ID=""
HEARTBEAT_PID=""

log() { printf 'DELvEKBot: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

normalize_base() {
  local u="${1%/}"
  [[ -n "$u" ]] || return 1
  case "$u" in
    http://*|https://*) ;;
    *) u="https://$u" ;;
  esac
  printf '%s/' "$u"
}

api() {
  local method="$1" path="$2"
  shift 2
  curl -fsS \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" \
    -X "$method" \
    -H "X-Decrypt-Worker-Token: ${TOKEN}" \
    -H "X-AS-ADID: ${ADID}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "$@" \
    "${BASE}${path}"
}

is_null_job() {
  printf '%s' "$1" | jq -e '(.job == null) or (.job | not)' >/dev/null 2>&1
}

job_string() {
  local json="$1" key="$2"
  printf '%s' "$json" | jq -er --arg k "$key" \
    '.job[$k] | select(type == "string" and length > 0)' 2>/dev/null
}

progress() {
  local id="$1" msg="$2"
  local payload
  payload="$(jq -cn --arg id "$id" --arg msg "$msg" '{id:$id,msg:$msg}')"
  api POST "api/decrypt/worker/progress" -d "$payload" >/dev/null || true
}

fail_job() {
  local id="$1" err="$2"
  local payload
  payload="$(jq -cn --arg id "$id" --arg error "$err" '{id:$id,error:$error}')"
  api POST "api/decrypt/worker/fail" -d "$payload" >/dev/null || true
}

heartbeat_loop() {
  local id="$1"
  while sleep "$HEARTBEAT_SECONDS"; do
    progress "$id" "DELvEKBot · decrypt still running"
  done
}

stop_heartbeat() {
  if [[ -n "${HEARTBEAT_PID}" ]]; then
    kill "$HEARTBEAT_PID" >/dev/null 2>&1 || true
    wait "$HEARTBEAT_PID" >/dev/null 2>&1 || true
    HEARTBEAT_PID=""
  fi
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

itunes_lookup() {
  local store_url="$1" app_id body
  app_id="$(printf '%s' "$store_url" | sed -nE 's/.*\/id([0-9]{5,12})([^0-9].*)?$/\1/p' | head -1)"
  [[ -n "$app_id" ]] || app_id="$(printf '%s' "$store_url" | sed -nE 's/.*id([0-9]{5,12}).*/\1/p' | head -1)"
  [[ -n "$app_id" ]] || return 1

  body="$(curl -fsSL \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time 30 \
    "https://itunes.apple.com/lookup?id=${app_id}&country=${COUNTRY}" 2>/dev/null)" || return 1

  local result
  result="$(printf '%s' "$body" | jq -er \
    '.results[0] | select(.bundleId and .trackName) | [.bundleId,.trackName] | @tsv' 2>/dev/null)" || return 1
  printf '%s\n' "$result"
}

find_fresh_ipa() {
  local bid="$1" started_epoch="$2"
  local candidate
  local -a candidates=()

  while IFS= read -r -d '' candidate; do
    [[ -s "$candidate" ]] || continue
    local mtime
    mtime="$(stat -f '%m' "$candidate" 2>/dev/null || stat -c '%Y' "$candidate" 2>/dev/null || echo 0)"
    if [[ "$mtime" -ge "$started_epoch" ]]; then
      candidates+=("$candidate")
    fi
  done < <(find "$DOCS" -maxdepth 2 -type f \
      \( -name "${bid}.ipa" -o -name "${bid}_decrypted.ipa" -o -name "${bid}"'*.ipa' \) \
      -print0 2>/dev/null)

  ((${#candidates[@]} > 0)) || return 1

  local newest="" newest_mtime=0 mtime
  for candidate in "${candidates[@]}"; do
    mtime="$(stat -f '%m' "$candidate" 2>/dev/null || stat -c '%Y' "$candidate" 2>/dev/null || echo 0)"
    if [[ "$mtime" -ge "$newest_mtime" ]]; then
      newest="$candidate"
      newest_mtime="$mtime"
    fi
  done
  [[ -n "$newest" ]] || return 1
  printf '%s\n' "$newest"
}

upload_ipa() {
  local id="$1" ipa="$2" name="$3"
  local qname response

  [[ -s "$ipa" ]] || return 1
  qname="$(urlencode "$name")"

  response="$(curl -fsS \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$UPLOAD_MAX_TIME" \
    -X POST \
    -H "X-Decrypt-Worker-Token: ${TOKEN}" \
    -H "X-AS-ADID: ${ADID}" \
    -H "Content-Type: application/octet-stream" \
    -H "Accept: application/json" \
    --data-binary @"$ipa" \
    "${BASE}api/decrypt/worker/complete?id=${id}&name=${qname}")" || return 1

  printf '%s' "$response" | jq -e '
    type == "object" and
    (.ok != false) and
    (.success != false) and
    (has("error") | not)
  ' >/dev/null 2>&1
}

run_delvekbot() {
  # Always invoke under sudo when not root (defensive); main already elevated.
  if [[ "$(id -u)" -eq 0 ]]; then
    "${DELVEKBOT_BIN}" "$@"
  else
    sudo -E "${DELVEKBOT_BIN}" "$@"
  fi
}

handle_job() {
  local id="$1" url="$2"
  CURRENT_JOB_ID="$id"
  log "claimed ${id}"
  progress "$id" "DELvEKBot · resolving App Store listing"

  local lookup bid name
  lookup="$(itunes_lookup "$url")" || {
    fail_job "$id" "Could not resolve a bundle ID from the App Store URL."
    CURRENT_JOB_ID=""
    return 0
  }
  bid="${lookup%%$'\t'*}"
  name="${lookup#*$'\t'}"
  [[ -n "$bid" ]] || {
    fail_job "$id" "App Store lookup returned no bundle ID."
    CURRENT_JOB_ID=""
    return 0
  }
  [[ -n "$name" ]] || name="$bid"

  progress "$id" "DELvEKBot · ${bid}"

  local started_epoch
  started_epoch="$(date +%s)"
  local -a args=()
  [[ "$VERBOSE" == "1" ]] && args+=(-v)
  args+=("$bid")

  heartbeat_loop "$id" &
  HEARTBEAT_PID=$!

  set +e
  run_delvekbot "${args[@]}"
  local rc=$?
  set -e
  stop_heartbeat

  if [[ "$rc" -ne 0 ]]; then
    fail_job "$id" "DELvEKBot exited ${rc} for ${bid}. Install the app from the App Store on this device (iOS 26.0.1 / 16.2 / 15.4), then retry."
    CURRENT_JOB_ID=""
    return 0
  fi

  local ipa
  ipa="$(find_fresh_ipa "$bid" "$started_epoch")" || {
    fail_job "$id" "DELvEKBot finished, but no fresh IPA under ${DOCS} for ${bid}."
    CURRENT_JOB_ID=""
    return 0
  }

  progress "$id" "DELvEKBot · uploading $(basename "$ipa")"
  if upload_ipa "$id" "$ipa" "$name"; then
    log "uploaded ${name} (${bid}) ← ${ipa}"
  else
    fail_job "$id" "IPA upload failed or server returned invalid completion JSON."
  fi
  CURRENT_JOB_ID=""
}

cleanup() {
  stop_heartbeat
  if [[ -n "${CURRENT_JOB_ID}" ]]; then
    log "stopped while job ${CURRENT_JOB_ID} was active"
  fi
}
trap cleanup EXIT INT TERM

load_dotenv() {
  local envf="${SCRIPT_DIR}/.env"
  [[ -f "$envf" ]] || return 0
  set -a
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    [[ "$line" == *=* ]] || continue
    export "$line"
  done < "$envf"
  set +a
  SITE_URL="${DECRYPT_SITE_URL:-${MAC_PUBLIC_BASE:-$SITE_URL}}"
  TOKEN="${DECRYPT_WORKER_TOKEN:-$TOKEN}"
  DELVEKBOT_BIN="${DELVEKBOT_BIN:-${BUDDY3_BIN:-${SCRIPT_DIR}/DELvEKBot}}"
  DOCS="${DELVEKBOT_OUT_DIR:-${BUDDY3_OUT_DIR:-$DOCS}}"
  ADID="${DELVEKBOT_ADID:-${DECRYPT_WORKER_ADID:-$ADID}}"
  VERBOSE="${DELVEKBOT_VERBOSE:-${BUDDY3_VERBOSE:-$VERBOSE}}"
}

main() {
  load_dotenv

  need_cmd curl
  need_cmd jq
  need_cmd flock
  need_cmd find
  need_cmd stat
  need_cmd date

  [[ -n "$SITE_URL" ]] || die "set DECRYPT_SITE_URL=https://your-vps/ (or .env)"
  [[ -n "$TOKEN" ]] || die "set DECRYPT_WORKER_TOKEN (or .env)"
  # Resolve legacy buddy3 filename if DELvEKBot missing
  if [[ ! -x "$DELVEKBOT_BIN" && -x "${SCRIPT_DIR}/buddy3" ]]; then
    DELVEKBOT_BIN="${SCRIPT_DIR}/buddy3"
  fi
  [[ -x "$DELVEKBOT_BIN" ]] || die "DELvEKBot is not executable: ${DELVEKBOT_BIN}"
  [[ -d "$DOCS" ]] || die "output directory missing: ${DOCS}"
  [[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] && ((POLL_SECONDS >= 1)) || die "POLL_SECONDS must be >= 1"
  [[ "$HEARTBEAT_SECONDS" =~ ^[0-9]+$ ]] && ((HEARTBEAT_SECONDS >= 5)) || die "HEARTBEAT_SECONDS must be >= 5"

  BASE="$(normalize_base "$SITE_URL")" || die "invalid DECRYPT_SITE_URL"

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another DELvEKBot worker is already running (${LOCK_FILE})"

  log "uid=$(id -u) (root) · site=${BASE} · bin=${DELVEKBOT_BIN}"
  log "poll=${POLL_SECONDS}s · heartbeat=${HEARTBEAT_SECONDS}s · out=${DOCS}"

  while true; do
    local resp id url
    if ! resp="$(api POST "api/decrypt/worker/claim" \
        -d "$(jq -cn --arg adid "$ADID" '{adid:$adid}')" 2>/dev/null)"; then
      log "claim failed; retry in ${POLL_SECONDS}s"
      sleep "$POLL_SECONDS"
      continue
    fi

    if ! printf '%s' "$resp" | jq -e 'type == "object"' >/dev/null 2>&1; then
      log "invalid JSON from server; retry"
      sleep "$POLL_SECONDS"
      continue
    fi

    if is_null_job "$resp"; then
      sleep "$POLL_SECONDS"
      continue
    fi

    id="$(job_string "$resp" id || true)"
    url="$(job_string "$resp" url || true)"
    if [[ -z "$id" || -z "$url" ]]; then
      log "claim missing job.id / job.url; retry"
      sleep "$POLL_SECONDS"
      continue
    fi

    handle_job "$id" "$url"
    sleep 1
  done
}

main "$@"
