#!/usr/bin/env bash
# Host regression for fp_page / decrypt-order locks (no device / mremap required).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cc -std=c11 -Wall -Wextra -O2 -I "$ROOT/Sources/FairPlay" \
  "$ROOT/tests/fpcore/test_fp_page.c" -o /tmp/test_fp_page
/tmp/test_fp_page
