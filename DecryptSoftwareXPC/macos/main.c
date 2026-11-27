/*
 * decrypt.software XPC service entry
 * Product: software.decrypt.xpc · Brand: decrypt.software
 */
#include "ds_xpc.h"

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    return ds_xpc_server_run();
}
