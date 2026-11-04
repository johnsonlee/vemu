#!/usr/bin/env bash
set -euo pipefail
gpu_dir="${VEMU_HOME:-$HOME/.local/share/vemu}"
guest_user="${VEMU_GUEST_USER:-$USER}"
name=
while (($#)); do
    case "$1" in
        --name)
            option="$1"
            (($# >= 2)) || { printf 'Missing value for %s\n' "$option" >&2; exit 2; }
            name="$2"
            shift 2 ;;
        --help|-h)
            printf 'Usage: %s [--name NAME]\n' "$0"
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
if [[ -z "$name" && -f "$gpu_dir/active-name" ]]; then
    name="$(cat "$gpu_dir/active-name")"
fi
name="${name:-vemu}"
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { printf 'Invalid name: %s\n' "$name" >&2; exit 2; }
pidfile="$gpu_dir/qemu.pid"
label=io.johnsonlee.vemu
legacy_label=io.github.johnsonlee.vemu.qemu
if [[ ! -f "$pidfile" ]] || ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    printf 'GPU VM is stopped\n'
    exit 0
fi

ssh -i "$gpu_dir/ssh_key" -p 2223 -o BatchMode=yes -o ConnectTimeout=3 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$gpu_dir/known_hosts" \
    "$guest_user@127.0.0.1" "sudo docker stop '$name' >/dev/null; sudo poweroff" || true
for _ in {1..30}; do
    if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        rm -f "$pidfile"
        rm -f "$gpu_dir/active-name"
        launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
        launchctl bootout "gui/$(id -u)/$legacy_label" >/dev/null 2>&1 || true
        printf 'GPU VM stopped; Android data retained\n'
        exit 0
    fi
    sleep 1
done
printf 'GPU VM is still shutting down (PID %s)\n' "$(cat "$pidfile")" >&2
exit 1
