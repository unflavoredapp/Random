/*
 * decrypt.software — XPC client (hand-rolled C API)
 * Brand: decrypt.software
 */
#include "ds_xpc.h"

#include <stdio.h>
#include <string.h>
#include <dispatch/dispatch.h>

xpc_connection_t ds_xpc_client_connect(const char **err_out) {
    xpc_connection_t conn = xpc_connection_create_mach_service(
        DS_XPC_SERVICE_NAME,
        NULL,
        0
    );
    if (!conn) {
        if (err_out) *err_out = "xpc_connection_create_mach_service failed";
        return NULL;
    }
    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
        (void)event;
    });
    xpc_connection_resume(conn);
    if (err_out) *err_out = NULL;
    return conn;
}

static ds_xpc_err_t send_op(xpc_connection_t conn, xpc_object_t req,
                            xpc_object_t *reply_out, char *errbuf, size_t errlen) {
    if (!conn || !req) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "bad args");
        return DS_XPC_ERR_ARGS;
    }
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
    if (!reply) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "no reply");
        return DS_XPC_ERR_REPLY;
    }
    if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "XPC error reply");
        xpc_release(reply);
        return DS_XPC_ERR_CONNECT;
    }
    if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "non-dictionary reply");
        xpc_release(reply);
        return DS_XPC_ERR_REPLY;
    }
    if (!xpc_dictionary_get_bool(reply, DS_XPC_KEY_OK)) {
        const char *e = xpc_dictionary_get_string(reply, DS_XPC_KEY_ERROR);
        if (errbuf && errlen) snprintf(errbuf, errlen, "%s", e ? e : "remote error");
        xpc_release(reply);
        return DS_XPC_ERR_REMOTE;
    }
    if (reply_out) *reply_out = reply;
    else xpc_release(reply);
    return DS_XPC_OK;
}

ds_xpc_err_t ds_xpc_client_ping(xpc_connection_t conn, char *errbuf, size_t errlen) {
    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, DS_XPC_KEY_OP, DS_XPC_OP_PING);
    ds_xpc_err_t rc = send_op(conn, req, NULL, errbuf, errlen);
    xpc_release(req);
    return rc;
}

ds_xpc_err_t ds_xpc_client_version(xpc_connection_t conn, char *out, size_t outlen,
                                   char *errbuf, size_t errlen) {
    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, DS_XPC_KEY_OP, DS_XPC_OP_VERSION);
    xpc_object_t reply = NULL;
    ds_xpc_err_t rc = send_op(conn, req, &reply, errbuf, errlen);
    xpc_release(req);
    if (rc != DS_XPC_OK) return rc;
    const char *v = xpc_dictionary_get_string(reply, DS_XPC_KEY_VERSION);
    if (out && outlen) snprintf(out, outlen, "%s", v ? v : "");
    xpc_release(reply);
    return DS_XPC_OK;
}

ds_xpc_err_t ds_xpc_client_decrypt(xpc_connection_t conn,
                                   const char *in_path,
                                   const char *out_path,
                                   char *errbuf, size_t errlen) {
    if (!in_path || !out_path) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "in_path/out_path required");
        return DS_XPC_ERR_ARGS;
    }
    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, DS_XPC_KEY_OP, DS_XPC_OP_DECRYPT);
    xpc_dictionary_set_string(req, DS_XPC_KEY_IN_PATH, in_path);
    xpc_dictionary_set_string(req, DS_XPC_KEY_OUT_PATH, out_path);
    ds_xpc_err_t rc = send_op(conn, req, NULL, errbuf, errlen);
    xpc_release(req);
    return rc;
}
