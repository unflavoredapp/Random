#!/usr/bin/env bash
# Seal regression test for the zsign core (Linux or macOS with clang++, OpenSSL dev headers).
# Builds a copy of Sources/zsign (with a TEST-ONLY issuer patch so the throwaway self-signed cert works),
# signs synthetic Mach-O apps in parallel, and verifies the result with an independent Python checker.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp -r "$ROOT/Sources/zsign" "$W/zsign"; cp -r "$HERE/shim" "$HERE/id" "$HERE/harness.cpp" "$HERE/mkapp.py" "$HERE/check.py" "$W/"
(cd "$W/zsign" && patch -s openssl.cpp < "$HERE/test-only-openssl.patch")
cd "$W"
clang++ -std=c++17 -O2 -fblocks -w -Ishim -Izsign -Izsign/common -o tc harness.cpp shim/blocks_stub.c \
  zsign/common/common.cpp zsign/common/json.cpp zsign/common/base64.cpp zsign/archo.cpp zsign/macho.cpp \
  zsign/signing.cpp zsign/openssl.cpp zsign/bundle.cpp zsign/verify.cpp -lcrypto -lpthread
fail=0
for spec in "small 8 4 thin" "fat 40 40 fat" "tight 8 4 thin tight"; do
  set -- $spec; name=$1; rm -rf "app_$name"; mkdir -p "app_$name"
  python3 -I mkapp.py "app_$name" "$2" "$3" "$4" ${5:-}
  ./tc "app_$name/Payload" id/cert.p12 id/test.mobileprovision pw 1 > "$name.log" 2>&1 || true
  grep -a -q 'SIGN_RESULT=1' "$name.log" || { echo "FAIL sign: $name"; fail=1; continue; }
  python3 -I check.py "app_$name/Payload/Big.app" | tee "$name.check" | head -3
  grep -q 'INDEPENDENT_CHECK PASS' "$name.check" || fail=1
done
./tc "app_small/Payload" id/cert.p12 id/test.mobileprovision pw 1 tamper 2>&1 | grep -a 'TAMPER_SEAL_CHECK' || true
exit $fail
