/*
 * decrypt.software — XPC service listener (hand-rolled C API)
 * Brand: decrypt.software
 */
#include "ds_xpc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dispatch/dispatch.h>

static void peer_event(xpc_connection_t peer, xpc_object_t event) {
    xpc_type_t type = xpc_get_type(event);
    if (type == XPC_TYPE_ERROR) {
        if (event == XPC_ERROR_CONNECTION_INVALID || event == XPC_ERROR_TERMINATION_IMMINENT) {
            /* peer gone */
        }
        return;
    }
    if (type != XPC_TYPE_DICTIONARY) return;

    xpc_object_t reply = ds_xpc_handle_request(event);
    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
}

static void service_event(xpc_connection_t service, xpc_object_t event) {
    xpc_type_t type = xpc_get_type(event);
    if (type == XPC_TYPE_ERROR) {
        if (event == XPC_ERROR_CONNECTION_INVALID) {
            fprintf(stderr, "[%s] service connection invalid\n", DS_XPC_BRAND);
            exit(1);
        }
        return;
    }
    if (type != XPC_TYPE_CONNECTION) return;

    xpc_connection_t peer = (xpc_connection_t)event;
    xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
        peer_event(peer, msg);
    });
    xpc_connection_resume(peer);
}

int ds_xpc_server_run(void) {
    xpc_connection_t service = xpc_connection_create_mach_service(
        DS_XPC_SERVICE_NAME,
        dispatch_get_main_queue(),
        XPC_CONNECTION_MACH_SERVICE_LISTENER
    );
    if (!service) {
        fprintf(stderr, "[%s] failed to create listener for %s\n",
                DS_XPC_BRAND, DS_XPC_SERVICE_NAME);
        return 1;
    }

    xpc_connection_set_event_handler(service, ^(xpc_object_t event) {
        service_event(service, event);
    });
    xpc_connection_resume(service);

    fprintf(stderr, "[%s] XPC listening on %s · v%s\n",
            DS_XPC_BRAND, DS_XPC_SERVICE_NAME, DS_XPC_VERSION);
    dispatch_main();
    return 0;
}
