/*
 * decrypt.software — request / reply codec + op dispatch
 * Brand: decrypt.software
 */
#include "ds_xpc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

xpc_object_t ds_xpc_reply_ok(void) {
    xpc_object_t r = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_bool(r, DS_XPC_KEY_OK, true);
    xpc_dictionary_set_string(r, DS_XPC_KEY_BRAND, DS_XPC_BRAND);
    xpc_dictionary_set_string(r, DS_XPC_KEY_VERSION, DS_XPC_VERSION);
    return r;
}

xpc_object_t ds_xpc_reply_error(const char *message) {
    xpc_object_t r = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_bool(r, DS_XPC_KEY_OK, false);
    xpc_dictionary_set_string(r, DS_XPC_KEY_BRAND, DS_XPC_BRAND);
    xpc_dictionary_set_string(r, DS_XPC_KEY_VERSION, DS_XPC_VERSION);
    xpc_dictionary_set_string(r, DS_XPC_KEY_ERROR, message ? message : "error");
    return r;
}

static xpc_object_t handle_ping(void) {
    xpc_object_t r = ds_xpc_reply_ok();
    xpc_dictionary_set_string(r, DS_XPC_KEY_STATUS, "alive");
    xpc_dictionary_set_string(r, DS_XPC_KEY_DETAIL, DS_XPC_SITE);
    return r;
}

static xpc_object_t handle_version(void) {
    xpc_object_t r = ds_xpc_reply_ok();
    xpc_dictionary_set_string(r, DS_XPC_KEY_STATUS, DS_XPC_VERSION);
    return r;
}

static xpc_object_t handle_status(void) {
    xpc_object_t r = ds_xpc_reply_ok();
    xpc_dictionary_set_string(r, DS_XPC_KEY_STATUS, "ready");
    xpc_dictionary_set_string(r, DS_XPC_KEY_DETAIL, "hand-rolled XPC · " DS_XPC_BRAND);
    return r;
}

/*
 * Decrypt op: copy encrypted → out, then prefer UNFAIRPLAY_BIN if present.
 * The XPC boundary is the product; backends plug in without changing the wire.
 */
static int run_unfairplay_decrypt(const char *in_path, const char *out_path, char *err, size_t errlen) {
    const char *bin = getenv("UNFAIRPLAY_BIN");
    if (!bin || !bin[0]) bin = "unfairplay";

    char cmd[2048];
    /* Prefer: unfairplay decrypt --input … --output …  (DrWhax CLI shape). */
    snprintf(cmd, sizeof cmd,
             "\"%s\" decrypt --input \"%s\" --output \"%s\" 2>&1",
             bin, in_path, out_path);
    FILE *p = popen(cmd, "r");
    if (!p) {
        snprintf(err, errlen, "popen(%s) failed", bin);
        return -1;
    }
    char line[512];
    size_t used = 0;
    err[0] = 0;
    while (fgets(line, sizeof line, p)) {
        size_t n = strlen(line);
        if (used + n + 1 < errlen) {
            memcpy(err + used, line, n);
            used += n;
            err[used] = 0;
        }
    }
    int st = pclose(p);
    if (st != 0) {
        if (!err[0]) snprintf(err, errlen, "%s exited %d", bin, st);
        return -1;
    }
    return 0;
}

static int copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) return -1;
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return -1; }
    char buf[64 * 1024];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) { fclose(in); fclose(out); return -1; }
    }
    fclose(in);
    fclose(out);
    return 0;
}

static xpc_object_t handle_decrypt(xpc_object_t request) {
    const char *in_path = xpc_dictionary_get_string(request, DS_XPC_KEY_IN_PATH);
    const char *out_path = xpc_dictionary_get_string(request, DS_XPC_KEY_OUT_PATH);
    if (!in_path || !out_path || !in_path[0] || !out_path[0]) {
        return ds_xpc_reply_error("decrypt requires in_path and out_path");
    }
    struct stat st;
    if (stat(in_path, &st) != 0 || !S_ISREG(st.st_mode)) {
        return ds_xpc_reply_error("in_path missing or not a regular file");
    }

    char err[1024];
    if (run_unfairplay_decrypt(in_path, out_path, err, sizeof err) == 0) {
        xpc_object_t r = ds_xpc_reply_ok();
        xpc_dictionary_set_string(r, DS_XPC_KEY_STATUS, "decrypted");
        xpc_dictionary_set_string(r, DS_XPC_KEY_DETAIL, "unfairplay");
        return r;
    }

    /* No unfairplay / failed — stage a byte copy so the XPC path still exercises IO. */
    if (copy_file(in_path, out_path) != 0) {
        char msg[1200];
        snprintf(msg, sizeof msg, "decrypt backend failed (%s) and copy failed", err[0] ? err : "unknown");
        return ds_xpc_reply_error(msg);
    }
    xpc_object_t r = ds_xpc_reply_ok();
    xpc_dictionary_set_string(r, DS_XPC_KEY_STATUS, "staged");
    xpc_dictionary_set_string(r, DS_XPC_KEY_DETAIL,
                              err[0] ? err : "no unfairplay — copied encrypted bytes");
    return r;
}

xpc_object_t ds_xpc_handle_request(xpc_object_t request) {
    if (!request || xpc_get_type(request) != XPC_TYPE_DICTIONARY) {
        return ds_xpc_reply_error("expected dictionary request");
    }
    const char *op = xpc_dictionary_get_string(request, DS_XPC_KEY_OP);
    if (!op) return ds_xpc_reply_error("missing op");

    if (strcmp(op, DS_XPC_OP_PING) == 0) return handle_ping();
    if (strcmp(op, DS_XPC_OP_VERSION) == 0) return handle_version();
    if (strcmp(op, DS_XPC_OP_STATUS) == 0) return handle_status();
    if (strcmp(op, DS_XPC_OP_DECRYPT) == 0) return handle_decrypt(request);
    return ds_xpc_reply_error("unknown op");
}
