#!/usr/bin/env bash
# Generate a Feather / backloop-style SSL pack for *.tetherless.dev.
# Output lands in server/ota/public/ — deploy those files to the apex VPS
# (https://tetherless.dev/pack.json) and/or publish via publish-ota-pack.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/public"
DOMAIN="${CERT_DOMAIN:-tetherless.dev}"
DAYS="${CERT_DAYS:-825}"
CN="*.${DOMAIN}"

mkdir -p "$OUT"
cd "$OUT"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Private root CA (self-signed). Users install this once via the app's trust profile.
openssl req -x509 -newkey rsa:4096 -sha256 -days "$DAYS" -nodes \
  -keyout "$tmp/ca.key" -out ca.crt \
  -subj "/CN=Decrypt.Team Tetherless Root CA/O=Decrypt.Team/OU=OTA" \
  -addext "basicConstraints=critical,CA:true" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

# Leaf for *.tetherless.dev + apex (apex hosts the pack; loopback uses one label).
cat > "$tmp/leaf.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${CN},DNS:${DOMAIN}
EOF

openssl req -newkey rsa:2048 -nodes -keyout server.pem -out "$tmp/leaf.csr" \
  -subj "/CN=${CN}/O=Decrypt.Team/OU=OTA" >/dev/null 2>&1

openssl x509 -req -in "$tmp/leaf.csr" -CA ca.crt -CAkey "$tmp/ca.key" -CAcreateserial \
  -out "$tmp/leaf.crt" -days "$DAYS" -sha256 -extfile "$tmp/leaf.ext" >/dev/null 2>&1

cat "$tmp/leaf.crt" ca.crt > server.crt
rm -f "$tmp/ca.key" ca.srl 2>/dev/null || true

# Split the private key like classic backloop / Feather packs (key1 + key2).
python3 - <<'PY'
import json, pathlib
key = pathlib.Path("server.pem").read_text()
half = len(key) // 2
pack = {
    "cert": pathlib.Path("server.crt").read_text(),
    "key1": key[:half],
    "key2": key[half:],
    "ca": pathlib.Path("ca.crt").read_text(),
    "info": "Decrypt.Team tetherless.dev OTA pack (backloop.dev replacement). Install the CA once and enable Full Trust.",
}
pathlib.Path("pack.json").write_text(json.dumps(pack, indent=2) + "\n")
pathlib.Path("commonName.txt").write_text("*.tetherless.dev\n")
print("wrote pack for *.tetherless.dev")
PY

# Re-write commonName with actual CN if domain was overridden.
printf '%s\n' "$CN" > commonName.txt
openssl x509 -in server.crt -noout -subject -enddate -ext subjectAltName
