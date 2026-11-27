#!/usr/bin/env bash
# Compat shim — buddy3 was rebranded to DELvEKBot.
exec bash "$(cd "$(dirname "$0")" && pwd)/delvekbot-dopamine-worker.sh" "$@"
