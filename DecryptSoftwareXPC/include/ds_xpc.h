/*
 * decrypt.software — hand-rolled XPC protocol
 * Brand: decrypt.software
 *
 * Low-level <xpc/xpc.h> messages (not NSXPC proxies). Shared by the macOS
 * XPC service and any client that speaks the same dictionary ops.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <xpc/xpc.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Launchd / XPC service name (macOS Contents/XPCServices). */
#define DS_XPC_SERVICE_NAME "software.decrypt.xpc"

/** Public brand + domain. */
#define DS_XPC_BRAND "decrypt.software"
#define DS_XPC_SITE "https://decrypt.software"
#define DS_XPC_VERSION "1.0.0"

/* Dictionary keys */
#define DS_XPC_KEY_OP "op"
#define DS_XPC_KEY_OK "ok"
#define DS_XPC_KEY_ERROR "error"
#define DS_XPC_KEY_BRAND "brand"
#define DS_XPC_KEY_VERSION "version"
#define DS_XPC_KEY_IN_PATH "in_path"
#define DS_XPC_KEY_OUT_PATH "out_path"
#define DS_XPC_KEY_STATUS "status"
#define DS_XPC_KEY_DETAIL "detail"

/* ops */
#define DS_XPC_OP_PING "ping"
#define DS_XPC_OP_VERSION "version"
#define DS_XPC_OP_DECRYPT "decrypt"
#define DS_XPC_OP_STATUS "status"

typedef enum {
    DS_XPC_OK = 0,
    DS_XPC_ERR_ARGS = 1,
    DS_XPC_ERR_CONNECT = 2,
    DS_XPC_ERR_REPLY = 3,
    DS_XPC_ERR_REMOTE = 4,
    DS_XPC_ERR_IO = 5,
} ds_xpc_err_t;

/** Build a standard reply skeleton (ok / brand / version). Caller owns it. */
xpc_object_t ds_xpc_reply_ok(void);
xpc_object_t ds_xpc_reply_error(const char *message);

/** Handle one inbound request dictionary; returns a reply dictionary (owned). */
xpc_object_t ds_xpc_handle_request(xpc_object_t request);

/**
 * Client: connect to the decrypt.software XPC service.
 * On success returns a resumed connection; caller must xpc_release when done.
 * On failure returns NULL and sets *err_out (optional).
 */
xpc_connection_t ds_xpc_client_connect(const char **err_out);

/** Client helpers (synchronous). Return DS_XPC_OK or an error code. */
ds_xpc_err_t ds_xpc_client_ping(xpc_connection_t conn, char *errbuf, size_t errlen);
ds_xpc_err_t ds_xpc_client_version(xpc_connection_t conn, char *out, size_t outlen,
                                   char *errbuf, size_t errlen);
ds_xpc_err_t ds_xpc_client_decrypt(xpc_connection_t conn,
                                   const char *in_path,
                                   const char *out_path,
                                   char *errbuf, size_t errlen);

/** Server: run the XPC listener loop for DS_XPC_SERVICE_NAME (macOS service main). */
int ds_xpc_server_run(void);

#ifdef __cplusplus
}
#endif
