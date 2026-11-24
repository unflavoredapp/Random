#!/usr/bin/env bash
# Brand: Tetherless · https://tetherless.dev
#
# Telegram-bot decrypt worker for Dopamine + Cli/buddy3.
#
# Flow: user pastes an App Store link in your Telegram bot → Linux VPS queues
# the job → this script (on the jailbroken iPhone) claims it, runs buddy3,
# uploads the clear IPA → the bot delivers the file. No AppAssassin UI needed.
#
# Prerequisites (iPhone 11 · Dopamine · iOS 26.0.1):
#   1) VPS: TELEGRAM_BOT_TOKEN + DECRYPT_BACKENDS=phone + DECRYPT_WORKER_TOKEN
#      (server/linux-host.env.example → linux-install.sh)
#   2) buddy3 on the phone, e.g.:
#        scp Cli/buddy3 mobile@iphone:/var/mobile/Documents/buddy3
#        ssh mobile@iphone 'chmod +x /var/mobile/Documents/buddy3'
#   3) Target apps installed from the App Store on this phone (same Apple ID).
#
# On the iPhone (NewTerm / SSH as mobile):
#   export DECRYPT_SITE_URL=https://your-vps.example/
#   export DECRYPT_WORKER_TOKEN=…          # same as /etc/tetherless/linux-host.env
#   export BUDDY3_BIN=/var/mobile/Documents/buddy3
#   bash buddy3-dopamine-worker.sh
#
# Optional:
#   BUDDY3_VERBOSE=1     # pass -v to buddy3
#   POLL_SECONDS=3       # claim loop interval
#   COUNTRY=us           # iTunes lookup country for App Store URLs
#
# Always elevates with sudo on Dopamine (buddy3 needs root for live installs).
#
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo "buddy3-worker: sudo is required on Dopamine" >&2
    exit 1
  }
  exec sudo -E bash "$0" "$@"
fi

SITE_URL="${DECRYPT_SITE_URL:-${MAC_PUBLIC_BASE:-}}"
TOKEN="${DECRYPT_WORKER_TOKEN:-}"
BUDDY3_BIN="${BUDDY3_BIN:-/var/mobile/Documents/buddy3}"
POLL_SECONDS="${POLL_SECONDS:-3}"
COUNTRY="${COUNTRY:-us}"
ADID="${DECRYPT_WORKER_ADID:-buddy3-dopamine}"
DOCS="${BUDDY3_OUT_DIR:-/var/mobile/Documents}"

die() { echo "buddy3-worker: $*" >&2; exit 1; }

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

# Random/Tetherless claim: { "ok": true, "job": { "id", "url", "version" } | null }
job_field() {
  local json="$1" key="$2"
  printf '%s' "$json" | tr '\n' ' ' | sed -n \
    "s/.*\"job\"[[:space:]]*:[[:space:]]*{[^}]*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
    | head -1
}

json_null_job() {
  local json="$1"
  local flat
  flat="$(printf '%s' "$json" | tr '\n' ' ')"
  printf '%s' "$flat" | grep -q '"job"[[:space:]]*:[[:space:]]*null' && return 0
  # No job object at all
  printf '%s' "$flat" | grep -q '"job"[[:space:]]*:' && return 1
  return 0
}

json_escape() {
  # Escape a short string for JSON (ASCII-safe; strips quotes/newlines).
  printf '%s' "$1" | tr '\n\r"' '   ' | cut -c1-200
}

itunes_lookup() {
  local store_url="$1"
  local app_id
  app_id="$(printf '%s' "$store_url" | sed -n 's/.*id\([0-9]\{5,12\}\).*/\1/p' | head -1)"
  [[ -n "$app_id" ]] || return 1
  local body
  body="$(curl -fsSL --max-time 20 \
    "https://itunes.apple.com/lookup?id=${app_id}&country=${COUNTRY}" 2>/dev/null)" || return 1
  local bid name
  bid="$(printf '%s' "$body" | sed -n 's/.*"bundleId":"\([^"]*\)".*/\1/p' | head -1)"
  name="$(printf '%s' "$body" | sed -n 's/.*"trackName":"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$bid" ]] || return 1
  printf '%s\t%s\n' "$bid" "$name"
}

api() {
  local method="$1" path="$2"
  shift 2
  curl -fsS --max-time 60 -X "$method" \
    -H "X-Decrypt-Worker-Token: ${TOKEN}" \
    -H "X-AS-ADID: ${ADID}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "$@" \
    "${BASE}${path}"
}

progress() {
  local id="$1" msg
  msg="$(json_escape "$2")"
  api POST "api/decrypt/worker/progress" \
    -d "{\"id\":\"${id}\",\"msg\":\"${msg}\"}" \
    >/dev/null || true
}

fail_job() {
  local id="$1" err
  err="$(json_escape "$2")"
  api POST "api/decrypt/worker/fail" \
    -d "{\"id\":\"${id}\",\"error\":\"${err}\"}" \
    >/dev/null || true
}

upload_ipa() {
  local id="$1" ipa="$2" name="$3"
  local qname
  qname="$(printf '%s' "$name" | sed 's/ /%20/g')"
  curl -fsS --max-time 600 -X POST \
    -H "X-Decrypt-Worker-Token: ${TOKEN}" \
    -H "X-AS-ADID: ${ADID}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$ipa" \
    "${BASE}api/decrypt/worker/complete?id=${id}&name=${qname}"
}

find_buddy_ipa() {
  local bid="$1"
  local cand
  for cand in \
    "${DOCS}/${bid}.ipa" \
    "${DOCS}/${bid}_decrypted.ipa"
  do
    if [[ -f "$cand" && -s "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  # Newest matching IPA under Documents (fallback).
  local newest
  newest="$(ls -t "${DOCS}/${bid}"*.ipa 2>/dev/null | head -1 || true)"
  [[ -n "$newest" && -f "$newest" ]] || return 1
  printf '%s\n' "$newest"
}

handle_job() {
  local id="$1" url="$2"
  echo "buddy3-worker: claimed ${id} · ${url}"
  progress "$id" "buddy3 · resolving App Store id…"

  local lookup bid name
  lookup="$(itunes_lookup "$url")" || {
    fail_job "$id" "Could not resolve bundle ID from App Store URL."
    return 0
  }
  bid="${lookup%%$'\t'*}"
  name="${lookup#*$'\t'}"
  [[ -n "$name" ]] || name="$bid"
  progress "$id" "buddy3 · ${bid}"

  local args=()
  [[ "${BUDDY3_VERBOSE:-0}" == "1" ]] && args+=(-v)
  args+=("$bid")

  progress "$id" "buddy3 · decrypting (app must be App Store–installed)…"
  set +e
  "${BUDDY3_BIN}" "${args[@]}"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    fail_job "$id" "buddy3 exit ${rc} for ${bid}. Install the app from the App Store on this Dopamine device (iOS 26.0.1), then retry."
    return 0
  fi

  local ipa
  ipa="$(find_buddy_ipa "$bid")" || {
    fail_job "$id" "buddy3 finished but no IPA under ${DOCS} for ${bid}."
    return 0
  }

  progress "$id" "buddy3 · uploading $(basename "$ipa")…"
  if upload_ipa "$id" "$ipa" "$name" >/dev/null; then
    echo "buddy3-worker: uploaded ${name} ← ${ipa}"
  else
    fail_job "$id" "Upload to VPS failed."
  fi
}

main() {
  need_cmd curl
  need_cmd sed
  [[ -n "$SITE_URL" ]] || die "set DECRYPT_SITE_URL=https://your-vps/"
  [[ -n "$TOKEN" ]] || die "set DECRYPT_WORKER_TOKEN (same as VPS linux-host.env)"
  [[ -x "$BUDDY3_BIN" ]] || die "buddy3 not executable at BUDDY3_BIN=${BUDDY3_BIN}"

  BASE="$(normalize_base "$SITE_URL")" || die "bad DECRYPT_SITE_URL"
  echo "buddy3-worker: uid=$(id -u) (root) · site=${BASE} · bin=${BUDDY3_BIN} · poll=${POLL_SECONDS}s"
  echo "buddy3-worker: install target apps from the App Store first; buddy3 supports iOS 15.4 / 16.2 / 26.0.1"

  while true; do
    local resp job id url
    set +e
    resp="$(api POST "api/decrypt/worker/claim" -d "{\"adid\":\"${ADID}\"}" 2>/dev/null)"
    local claim_rc=$?
    set -e
    if [[ $claim_rc -ne 0 || -z "$resp" ]]; then
      echo "buddy3-worker: claim error (check URL/token/HTTPS) — retry in ${POLL_SECONDS}s"
      sleep "$POLL_SECONDS"
      continue
    fi
    if json_null_job "$resp"; then
      sleep "$POLL_SECONDS"
      continue
    fi
    id="$(job_field "$resp" id)"
    url="$(job_field "$resp" url)"
    if [[ -z "$id" || -z "$url" ]]; then
      echo "buddy3-worker: claim missing job.id / job.url — retry in ${POLL_SECONDS}s"
      sleep "$POLL_SECONDS"
      continue
    fi
    handle_job "$id" "$url"
    sleep 1
  done
}

main "$@"
