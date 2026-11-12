Z=$1; OUT=$2; EXTRA=""
[ -f $Z/verify.cpp ] && EXTRA="$Z/verify.cpp" || EXTRA="-DNO_VERIFY"
clang++ -std=c++17 -O2 -fblocks -w -Ishim -I$Z -I$Z/common -o $OUT $3 shim/blocks_stub.c \
  $Z/common/common.cpp $Z/common/json.cpp $Z/common/base64.cpp $Z/archo.cpp $Z/macho.cpp $Z/signing.cpp $Z/openssl.cpp $Z/bundle.cpp $EXTRA -lcrypto -lpthread 2>&1 | grep -E "error|undefined" | head
