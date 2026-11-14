//
//  PKCS12Builder.c
//  Build a passworded PKCS#12 from PEM certificate + private key (OpenSSL).
//

#include "PKCS12Builder.h"

#include <openssl/bio.h>
#include <openssl/buffer.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int tl_pkcs12_from_pem(
    const unsigned char *cert_pem, size_t cert_len,
    const unsigned char *key_pem, size_t key_len,
    const char *password,
    unsigned char **out_der, size_t *out_len,
    char *err, size_t errlen
) {
    if (out_der) *out_der = NULL;
    if (out_len) *out_len = 0;
    if (!cert_pem || !key_pem || !out_der || !out_len) {
        if (err && errlen) snprintf(err, errlen, "bad arguments");
        return -1;
    }

    BIO *certBio = BIO_new_mem_buf(cert_pem, (int)cert_len);
    BIO *keyBio = BIO_new_mem_buf(key_pem, (int)key_len);
    X509 *cert = NULL;
    EVP_PKEY *pkey = NULL;
    PKCS12 *p12 = NULL;
    BIO *outBio = NULL;
    int rc = -1;

    if (!certBio || !keyBio) {
        if (err && errlen) snprintf(err, errlen, "BIO alloc failed");
        goto done;
    }

    cert = PEM_read_bio_X509(certBio, NULL, NULL, NULL);
    if (!cert) {
        BIO_reset(certBio);
        cert = d2i_X509_bio(certBio, NULL);
    }
    if (!cert) {
        if (err && errlen) snprintf(err, errlen, "couldn't parse certificate PEM");
        goto done;
    }

    pkey = PEM_read_bio_PrivateKey(keyBio, NULL, NULL, NULL);
    if (!pkey) {
        BIO_reset(keyBio);
        pkey = d2i_PrivateKey_bio(keyBio, NULL);
    }
    if (!pkey) {
        if (err && errlen) snprintf(err, errlen, "couldn't parse private key PEM");
        goto done;
    }

    if (!X509_check_private_key(cert, pkey)) {
        if (err && errlen) snprintf(err, errlen, "certificate/key mismatch");
        goto done;
    }

    const char *pass = password ? password : "";
    p12 = PKCS12_create(
        (char *)pass,
        (char *)"TetherLess",
        pkey,
        cert,
        NULL,
        0, 0, 0, 0, 0
    );
    if (!p12) {
        if (err && errlen) snprintf(err, errlen, "PKCS12_create failed");
        goto done;
    }

    outBio = BIO_new(BIO_s_mem());
    if (!outBio || !i2d_PKCS12_bio(outBio, p12)) {
        if (err && errlen) snprintf(err, errlen, "i2d_PKCS12_bio failed");
        goto done;
    }

    BUF_MEM *mem = NULL;
    BIO_get_mem_ptr(outBio, &mem);
    if (!mem || !mem->data || mem->length == 0) {
        if (err && errlen) snprintf(err, errlen, "empty PKCS12");
        goto done;
    }

    unsigned char *buf = (unsigned char *)malloc(mem->length);
    if (!buf) {
        if (err && errlen) snprintf(err, errlen, "malloc failed");
        goto done;
    }
    memcpy(buf, mem->data, mem->length);
    *out_der = buf;
    *out_len = mem->length;
    rc = 0;

done:
    if (p12) PKCS12_free(p12);
    if (pkey) EVP_PKEY_free(pkey);
    if (cert) X509_free(cert);
    if (certBio) BIO_free(certBio);
    if (keyBio) BIO_free(keyBio);
    if (outBio) BIO_free(outBio);
    return rc;
}

void tl_pkcs12_free(unsigned char *p) {
    free(p);
}
