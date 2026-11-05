#!/usr/bin/env bash
set -euo pipefail

adb_bin="${VEMU_ADB_BIN:-}"
[[ -n "$adb_bin" && -x "$adb_bin" ]] || {
    printf 'VEMU_ADB_BIN must point to adb\n' >&2
    exit 1
}

args=()
for arg in "$@"; do
    if [[ "$arg" == CLASSPATH=/data/local/tmp/scrcpy-server.jar ]]; then
        args+=(su 1000 env)
    fi
    args+=("$arg")
done
exec "$adb_bin" "${args[@]}"
