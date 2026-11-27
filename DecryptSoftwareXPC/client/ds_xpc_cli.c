/*
 * decrypt.software — tiny CLI client for the hand-rolled XPC service
 * Usage:
 *   ds-xpc ping
 *   ds-xpc version
 *   ds-xpc status
 *   ds-xpc decrypt <in.ipa> <out.ipa>
 */
#include "ds_xpc.h"

#include <stdio.h>
#include <string.h>

static void usage(const char *argv0) {
    fprintf(stderr,
            "%s — %s XPC client\n"
            "  %s ping\n"
            "  %s version\n"
            "  %s status\n"
            "  %s decrypt <in_path> <out_path>\n"
            "Service: %s\n",
            argv0, DS_XPC_BRAND, argv0, argv0, argv0, argv0, DS_XPC_SERVICE_NAME);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(argv[0]); return 2; }

    const char *cerr = NULL;
    xpc_connection_t conn = ds_xpc_client_connect(&cerr);
    if (!conn) {
        fprintf(stderr, "connect failed: %s\n", cerr ? cerr : "?");
        fprintf(stderr, "Embed software.decrypt.xpc next to the host app, or run the service under launchd.\n");
        return 1;
    }

    char err[1024] = {0};
    ds_xpc_err_t rc = DS_XPC_OK;
    const char *op = argv[1];

    if (strcmp(op, "ping") == 0 || strcmp(op, "status") == 0) {
        xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(req, DS_XPC_KEY_OP,
                                  strcmp(op, "ping") == 0 ? DS_XPC_OP_PING : DS_XPC_OP_STATUS);
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, req);
        xpc_release(req);
        if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
            fprintf(stderr, "%s: bad reply\n", op);
            rc = DS_XPC_ERR_REPLY;
        } else {
            const char *st = xpc_dictionary_get_string(reply, DS_XPC_KEY_STATUS);
            const char *det = xpc_dictionary_get_string(reply, DS_XPC_KEY_DETAIL);
            const char *brand = xpc_dictionary_get_string(reply, DS_XPC_KEY_BRAND);
            printf("%s ok=%d brand=%s status=%s detail=%s\n",
                   op,
                   xpc_dictionary_get_bool(reply, DS_XPC_KEY_OK) ? 1 : 0,
                   brand ? brand : "?",
                   st ? st : "-",
                   det ? det : "-");
            xpc_release(reply);
        }
    } else if (strcmp(op, "version") == 0) {
        char ver[64];
        rc = ds_xpc_client_version(conn, ver, sizeof ver, err, sizeof err);
        if (rc == DS_XPC_OK) printf("version %s (%s)\n", ver, DS_XPC_BRAND);
        else fprintf(stderr, "version failed: %s\n", err);
    } else if (strcmp(op, "decrypt") == 0) {
        if (argc < 4) { usage(argv[0]); xpc_release(conn); return 2; }
        rc = ds_xpc_client_decrypt(conn, argv[2], argv[3], err, sizeof err);
        if (rc == DS_XPC_OK) printf("decrypt ok → %s\n", argv[3]);
        else fprintf(stderr, "decrypt failed: %s\n", err);
    } else {
        usage(argv[0]);
        xpc_release(conn);
        return 2;
    }

    xpc_release(conn);
    return rc == DS_XPC_OK ? 0 : 1;
}
