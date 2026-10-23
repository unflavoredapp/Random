#!/usr/bin/env bash
#
# build.sh — produce an UNSIGNED .ipa from the unzip-drop Xcode project.
# Runs on the GitHub Actions macOS runner (and any Mac). No signing identity,
# no exportArchive: we archive with signing disabled, lift the .app out of the
# archive, and zip it into Payload/ ourselves. On failure the real compiler
# errors are printed — not just a non-zero exit.
#
set -uo pipefail   # NOT -e: failures are caught and explained below

APP_NAME="${APP_NAME:-unzip-drop}"
SCHEME="${SCHEME:-unzip-drop}"
CONFIG="${CONFIG:-Release}"

# Repo root = the directory this script lives in (build.sh sits at the root).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PROJECT="$(ls -d ./*.xcodeproj 2>/dev/null | head -n1)"
if [ -z "$PROJECT" ]; then
  # Not next to build.sh: look a few levels down and build from where the project lives.
  FOUND="$(find "$ROOT" -maxdepth 4 -type d -name '*.xcodeproj' -not -path '*/build/*' -not -path '*/.git/*' 2>/dev/null | head -n1)"
  if [ -n "$FOUND" ]; then ROOT="$(cd "$(dirname "$FOUND")" && pwd)"; cd "$ROOT"; PROJECT="./$(basename "$FOUND")"; fi
fi
if [ -z "$PROJECT" ]; then
  echo "ERROR: no .xcodeproj found under $ROOT. The repo is missing the Xcode project (unzip-drop.xcodeproj)."
  echo "Repo contents:"; ls -la "$ROOT"; find "$ROOT" -maxdepth 2 -not -path '*/.git/*' | head -80
  exit 1
fi

BUILD_DIR="build"
DERIVED="$BUILD_DIR/DerivedData"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
OUT="$BUILD_DIR/ipa"
LOG="$BUILD_DIR/xcodebuild.log"

mkdir -p "$BUILD_DIR" "$OUT"
: > "$LOG"

hr() { printf '%s\n' "------------------------------------------------------------"; }

dump_errors() {
  echo ""; hr
  echo "BUILD FAILED (exit $1) — extracted errors:"; hr
  grep -nE "error:|fatal error:|\*\* .*FAILED \*\*|Undefined symbols?|linker command failed|No such module|cannot find |does not conform|Command .* failed|ambiguous|redeclaration" "$LOG" \
    | grep -v "^.*warning:" | tail -n 120 || echo "(no matching error lines — see full log below)"
  echo ""; echo "----- last 60 lines of $LOG -----"; tail -n 60 "$LOG"
  echo ""; echo "Full log saved at: $LOG"
}

run() {
  echo ""; echo "==> $*"
  ( "$@" ) 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || { dump_errors "$rc"; exit "$rc"; }
}

run_soft() {
  echo ""; echo "==> (soft) $*"
  ( "$@" ) 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || echo "   (non-fatal: exited $rc, continuing)"
}

echo "==> Environment"
echo "    root    : $ROOT"
echo "    project : $PROJECT"
echo "    scheme  : $SCHEME ($CONFIG)"
xcodebuild -version 2>&1 | tee -a "$LOG" || true
echo "    swift   : $(swift --version 2>/dev/null | head -n1)"
echo "    sources : $(find Sources -name '*.swift' | wc -l | tr -d ' ') swift, $(find Sources -name '*.cpp' -o -name '*.mm' | wc -l | tr -d ' ') c++/objc++"

# Quick brace sanity per Swift file — catches pasted-tail junk before xcodebuild does.
while IFS= read -r f; do
  o=$(tr -cd '{' < "$f" | wc -c); c=$(tr -cd '}' < "$f" | wc -c)
  [ "$o" -eq "$c" ] || echo "    WARN brace mismatch in $f ({ $o vs } $c)"
done < <(find Sources -name '*.swift')

# Native device installer: fetch the pinned IDeviceKit, apply the overlays and build the
# idevice XCFramework (needs rustup; macos runner has it). Skip with SKIP_NATIVE=1 only if
# you also remove the IDeviceKit package + AirShareDeviceTunnel target from the project.
if [ "${SKIP_NATIVE:-0}" != "1" ]; then
  echo ""; hr; echo "==> Native device library"; hr
  TOOLCHAIN="$(python3 -c 'import json;print(json.load(open("Native/Device/source.json"))["rust_toolchain"])')"
  if command -v rustup >/dev/null 2>&1; then
    run rustup toolchain install "$TOOLCHAIN" --profile minimal
  fi
  run python3 .github/scripts/fetch_devicekit.py
  run python3 .github/scripts/integrate_devicekit.py
  run python3 .github/scripts/build_device_native.py
fi

echo ""; echo "==> Schemes"
run_soft xcodebuild -list -project "$PROJECT"

# Resolve SwiftPM deps (ZIPFoundation, OpenSSL, Vapor). Archive re-resolves if this hiccups.
# Keep SwiftPM on the pinned Vapor / swift-crypto graph from project.pbxproj.
# This avoids the newer CryptoExtras graph that was failing in the simulator compile.
rm -rf "$DERIVED" 2>/dev/null || true
run_soft xcodebuild -project "$PROJECT" -scheme "$SCHEME" -resolvePackageDependencies \
  -derivedDataPath "$DERIVED" -skipPackagePluginValidation

# Archive, fully unsigned.
run xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation -skipPackagePluginValidation \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" \
  clean archive

APP_PATH="$(ls -d "$ARCHIVE"/Products/Applications/*.app 2>/dev/null | head -n1)"
[ -n "$APP_PATH" ] || { echo "ERROR: no .app inside $ARCHIVE"; dump_errors 1; exit 1; }
echo ""; echo "==> Built: $APP_PATH"

# Package: Payload/<App>.app → .ipa (no exportArchive — that needs a signing identity).
rm -rf "$OUT"; mkdir -p "$OUT/Payload"
cp -R "$APP_PATH" "$OUT/Payload/"
# Re-signers (zsign) need write access to every Mach-O (Xcode ships some mode 0555).
chmod -R u+rwX "$OUT/Payload"
# Strip anything that can't ship unsigned / isn't needed for sideloading.
find "$OUT/Payload" -name "_CodeSignature" -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT/Payload" -name "embedded.mobileprovision" -delete 2>/dev/null || true
# The native installer's VPN needs packet-tunnel-provider on BOTH the app and the appex.
# An unsigned binary carries no entitlements, so (unless ADHOC_ENTITLEMENTS=0) ad-hoc sign
# inside-out with the entitlement files so re-signers can see and preserve the request.
# This is not a valid distribution signature — the IPA still has to be re-signed.
APPEX="$(ls -d "$OUT"/Payload/*.app/PlugIns/AirShareDeviceTunnel.appex 2>/dev/null | head -n1)"
if [ -n "$APPEX" ]; then
  echo "==> Embedded tunnel extension: $APPEX"
  if [ "${ADHOC_ENTITLEMENTS:-1}" = "1" ]; then
    APPDIR="$(ls -d "$OUT"/Payload/*.app | head -n1)"
    while IFS= read -r b; do
      codesign --force --sign - --timestamp=none "$b" 2>&1 | tee -a "$LOG" || true
    done < <(find "$APPDIR" -depth \( -name '*.framework' -o -name '*.dylib' \) -not -path "$APPEX/*" 2>/dev/null)
    codesign --force --sign - --timestamp=none --entitlements "$ROOT/AirShareDeviceTunnel/AirShareDeviceTunnel.entitlements" "$APPEX" 2>&1 | tee -a "$LOG" || true
    codesign --force --sign - --timestamp=none --entitlements "$ROOT/unzip-drop.entitlements" "$APPDIR" 2>&1 | tee -a "$LOG" || true
  fi
else
  echo "WARN: AirShareDeviceTunnel.appex is not embedded — native install will report 'no VPN extension'."
fi
( cd "$OUT" && zip -qry "$APP_NAME.ipa" Payload && rm -rf Payload )

# Sanity: the IPA unzips and has an Info.plist.
if ! unzip -tq "$OUT/$APP_NAME.ipa" >/dev/null 2>&1; then echo "ERROR: IPA is not a valid zip"; exit 1; fi
unzip -l "$OUT/$APP_NAME.ipa" | grep -q "Payload/.*\.app/Info.plist" || { echo "ERROR: no Info.plist in IPA"; exit 1; }

echo ""; hr
echo "SUCCESS — $OUT/$APP_NAME.ipa"
ls -lh "$OUT/$APP_NAME.ipa"
hr
