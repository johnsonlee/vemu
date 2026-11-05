#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
server="$script_dir/../assets/scrcpy-secure-server-4.1.apk"
command -v scrcpy >/dev/null || { printf 'scrcpy is required: brew install scrcpy\n' >&2; exit 1; }
command -v adb >/dev/null || { printf 'adb is required: brew install android-platform-tools\n' >&2; exit 1; }
[[ -f "$server" ]] || { printf 'Missing secure scrcpy server: %s\n' "$server" >&2; exit 1; }
if [[ "$(scrcpy --version | head -1)" != scrcpy\ 4.1\ * ]]; then
    printf 'Secure view requires scrcpy 4.1 to match the bundled server\n' >&2
    exit 1
fi

VEMU_ADB_BIN="$(command -v adb)"
export VEMU_ADB_BIN
export ADB="$script_dir/secure-adb.sh"
export SCRCPY_SERVER_PATH="$server"
exec scrcpy -s 127.0.0.1:5556 "$@"
