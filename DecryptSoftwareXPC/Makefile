# decrypt.software — hand-rolled XPC (macOS)
# Brand: decrypt.software · service: software.decrypt.xpc
#
#   make              # build XPC bundle + CLI into build/
#   make test-ping    # requires the service reachable (embedded or launchd)

BRAND       := decrypt.software
SERVICE     := software.decrypt.xpc
BUILD       := build
XPC_ROOT    := $(BUILD)/$(SERVICE)
XPC_MACOS   := $(XPC_ROOT)/Contents/MacOS
XPC_EXEC    := $(XPC_MACOS)/$(SERVICE)

CC          ?= clang
CFLAGS      ?= -std=c11 -Wall -Wextra -O2 -fobjc-arc
CPPFLAGS    += -I include
LDFLAGS     += -framework System -framework Foundation

SRCS_LIB    := src/ds_xpc_protocol.c src/ds_xpc_server.c src/ds_xpc_client.c
SRCS_SVC    := macos/main.c $(SRCS_LIB)
SRCS_CLI    := client/ds_xpc_cli.c src/ds_xpc_protocol.c src/ds_xpc_client.c

.PHONY: all clean tree test-ping check-host

# Apple XPC headers are Darwin-only.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  HOST_OK := 1
else
  HOST_OK := 0
endif

check-host:
	@if [ "$(HOST_OK)" != "1" ]; then \
	  echo "decrypt.software XPC builds on macOS only (need <xpc/xpc.h>). On Linux: sources + Make are ready for a Mac."; \
	  exit 1; \
	fi

all: check-host $(XPC_EXEC) $(BUILD)/ds-xpc tree

$(XPC_MACOS):
	mkdir -p "$@"

$(XPC_EXEC): $(SRCS_SVC) include/ds_xpc.h macos/Info.plist | $(XPC_MACOS)
	$(CC) $(CFLAGS) $(CPPFLAGS) $(SRCS_SVC) -o "$@" $(LDFLAGS)
	cp macos/Info.plist $(XPC_ROOT)/Contents/Info.plist
	@echo "built $(XPC_ROOT)  [$(BRAND)]"

$(BUILD)/ds-xpc: $(SRCS_CLI) include/ds_xpc.h | $(BUILD)
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(CPPFLAGS) $(SRCS_CLI) -o "$@" $(LDFLAGS)

$(BUILD):
	mkdir -p "$@"

tree:
	@echo "$(BRAND) XPC layout:"
	@find $(XPC_ROOT) -type f 2>/dev/null | sed 's|^|  |' || true

test-ping: $(BUILD)/ds-xpc
	$(BUILD)/ds-xpc ping

clean:
	rm -rf $(BUILD)
