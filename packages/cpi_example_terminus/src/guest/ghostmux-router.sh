#!/bin/sh
set -eu
if [ "${1-}" = "-S" ]; then
    shift 2
    exec "$CPI2_GHOSTMUX_BIN" -S "$CPI2_GHOSTMUX_SOCKET" "$@"
fi
exec "$CPI2_GHOSTMUX_BIN" "$@"
