//
//  PKCS12Builder.h
//  Build a passworded PKCS#12 (.p12) from PEM certificate + private key via OpenSSL.
//

#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns 0 on success. Caller must free *out_der with tl_pkcs12_free.
int tl_pkcs12_from_pem(
    const unsigned char *cert_pem, size_t cert_len,
    const unsigned char *key_pem, size_t key_len,
    const char *password,
    unsigned char **out_der, size_t *out_len,
    char *err, size_t errlen
);

void tl_pkcs12_free(unsigned char *p);

#ifdef __cplusplus
}
#endif
