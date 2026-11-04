#!/usr/bin/env bash
# Remote commands intentionally expand validated local profile, name, and hash values.
# shellcheck disable=SC2029
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
skill_dir="$(dirname "$script_dir")"
cd "$script_dir/../../../.."
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: %s start|stop [--profile PROFILE] [--name NAME] [--apk PATH]\n' "$0"
    exit 0
fi
if (($# == 0)); then
    printf 'Usage: %s start|stop [--profile PROFILE] [--name NAME] [--apk PATH]\n' "$0" >&2
    exit 2
fi
action="$1"
shift
profile=default
name=
apk=
gpu_dir="${VEMU_HOME:-$HOME/.local/share/vemu}"
guest_user="${VEMU_GUEST_USER:-$USER}"
while (($#)); do
    case "$1" in
        --profile|-p|--name|--apk)
            option="$1"
            (($# >= 2)) || { printf 'Missing value for %s\n' "$option" >&2; exit 2; }
            case "$option" in
                --profile|-p) profile="$2" ;;
                --name) name="$2" ;;
                --apk) apk="$2" ;;
            esac
            shift 2 ;;
        --help|-h)
            printf 'Usage: %s start|stop [--profile PROFILE] [--name NAME] [--apk PATH]\n' "$0"
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$action" == start || "$action" == stop ]] || { printf 'Invalid action: %s\n' "$action" >&2; exit 2; }
if [[ "$action" == stop ]]; then
    [[ -z "$apk" ]] || { printf '%s\n' '--apk only applies to start' >&2; exit 2; }
    if [[ -z "$name" ]]; then
        exec "$script_dir/stop-gpu.sh"
    fi
    exec "$script_dir/stop-gpu.sh" --name "$name"
fi
name="${name:-vemu}"
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { printf 'Invalid name: %s\n' "$name" >&2; exit 2; }
[[ -z "$apk" || -f "$apk" ]] || { printf 'APK not found: %s\n' "$apk" >&2; exit 2; }
[[ "$profile" =~ ^[a-z0-9-]+$ && -f "profiles/$profile/profile.env" ]] || {
    printf 'Unknown profile: %s\n' "$profile" >&2
    exit 1
}
data_volume="$(sed -n 's/^ANDROID_DATA_VOLUME=//p' "profiles/$profile/profile.env")"
[[ "$data_volume" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || {
    printf 'Invalid Android data volume in profile: %s\n' "$profile" >&2
    exit 1
}

guest_host="$guest_user@127.0.0.1"
utm_app="$gpu_dir/UTM.app"
qemu_lib="$utm_app/Contents/Frameworks/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu"
qemu_resources="$utm_app/Contents/Resources/qemu"
disk="$gpu_dir/disk.raw"
ssh_key="$gpu_dir/ssh_key"
loader="$gpu_dir/qemu-loader"
pidfile="$gpu_dir/qemu.pid"
plist="$gpu_dir/qemu.launchd.plist"
label=io.github.johnsonlee.vemu.qemu

for required in "$qemu_lib" "$qemu_resources/edk2-aarch64-code.fd" "$disk" "$ssh_key"; do
    test -e "$required" || { printf 'Missing %s\n' "$required" >&2; exit 1; }
done

if [[ ! -x "$loader" || "$skill_dir/src/qemu-loader.c" -nt "$loader" || "$skill_dir/assets/gpu-entitlements.plist" -nt "$loader" ]]; then
    clang -Wl,-rpath,"$utm_app/Contents/Frameworks" -o "$loader" "$skill_dir/src/qemu-loader.c"
    codesign --force --sign - --entitlements "$skill_dir/assets/gpu-entitlements.plist" "$loader" >/dev/null
fi

if [[ ! -f "$pidfile" ]] || ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    rm -f "$gpu_dir/monitor.sock" "$gpu_dir/spice.sock"
    python3 - "$plist" "$loader" "$qemu_lib" "$qemu_resources" "$disk" "$gpu_dir" "$label" <<'PY'
import plistlib
import sys
from pathlib import Path

plist, loader, library, resources, disk, directory, label = sys.argv[1:]
arguments = [
    loader, library, "-L", resources, "-machine", "virt", "-accel", "hvf",
    "-cpu", "host", "-smp", "4", "-m", "6144", "-bios",
    f"{resources}/edk2-aarch64-code.fd", "-drive",
    f"if=none,file={disk},format=raw,id=hd0", "-device", "virtio-blk-pci,drive=hd0",
    "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:2223-:22,hostfwd=tcp:127.0.0.1:5556-:5555",
    "-device", "virtio-net-pci,netdev=net0,mac=52:55:55:1d:5c:cd",
    "-device", "virtio-gpu-gl-pci", "-display", "none", "-spice",
    f"unix=on,addr={directory}/spice.sock,disable-ticketing=on,gl=on",
    "-serial", f"file:{directory}/serial.log", "-monitor",
    f"unix:{directory}/monitor.sock,server,nowait",
]
job = {
    "Label": label,
    "ProgramArguments": arguments,
    "RunAtLoad": True,
    "KeepAlive": False,
    "StandardOutPath": f"{directory}/qemu.log",
    "StandardErrorPath": f"{directory}/qemu.log",
}
Path(plist).write_bytes(plistlib.dumps(job))
PY
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    for _ in {1..10}; do
        qemu_pid="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk '/^[[:space:]]*pid = / { print $3; exit }')"
        if [[ -n "$qemu_pid" ]]; then
            echo "$qemu_pid" > "$pidfile"
            break
        fi
        sleep 1
    done
    test -f "$pidfile" || { cat "$gpu_dir/qemu.log" >&2; exit 1; }
fi

ssh_args=(-i "$ssh_key" -p 2223 -o BatchMode=yes -o ConnectTimeout=3
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$gpu_dir/known_hosts")
ready=0
for _ in {1..60}; do
    if ssh "${ssh_args[@]}" "$guest_host" true 2>/dev/null; then
        ready=1
        break
    fi
    sleep 2
done
test "$ready" = 1 || { tail -40 "$gpu_dir/qemu.log" >&2; exit 1; }

ssh "${ssh_args[@]}" "$guest_host" 'sudo sh -s' < "$script_dir/provision-guest.sh"
ssh "${ssh_args[@]}" "$guest_host" 'sudo mkdir -p /opt/vemu'
LC_ALL=C tar -cf - compose.yaml compose.apk.yaml profiles | \
    ssh "${ssh_args[@]}" "$guest_host" 'sudo tar -C /opt/vemu -xf -'
ssh "${ssh_args[@]}" "$guest_host" "sudo docker volume create '$data_volume' >/dev/null"
compose_files='-f compose.yaml'
apk_guest_path=
if [[ -n "$apk" ]]; then
    apk_hash="$(LC_ALL=C shasum -a 256 "$apk" | awk '{print $1}')"
    [[ "$apk_hash" =~ ^[0-9a-f]{64}$ ]] || { printf 'Could not hash APK\n' >&2; exit 1; }
    apk_guest_path="/opt/vemu/apks/$apk_hash.apk"
    if ! ssh "${ssh_args[@]}" "$guest_host" "sudo test -f '$apk_guest_path'"; then
        ssh "${ssh_args[@]}" "$guest_host" 'sudo mkdir -p /opt/vemu/apks'
        apk_part="/opt/vemu/apks/$apk_hash.part"
        ssh "${ssh_args[@]}" "$guest_host" "sudo tee '$apk_part' >/dev/null" < "$apk"
        actual_hash="$(ssh "${ssh_args[@]}" "$guest_host" "sudo sha256sum '$apk_part'" | awk '{print $1}')"
        [[ "$actual_hash" == "$apk_hash" ]] || { printf 'APK transfer hash mismatch\n' >&2; exit 1; }
        ssh "${ssh_args[@]}" "$guest_host" "sudo mv '$apk_part' '$apk_guest_path'"
    fi
    compose_files="$compose_files -f compose.apk.yaml"
fi
ssh "${ssh_args[@]}" "$guest_host" "sudo sh -s -- '$name'" <<'GUEST'
set -eu
name="$1"
if docker container inspect "$name" >/dev/null 2>&1; then
    if [ "$(docker inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project"}}')" != vemu ]; then
        docker rm -f "$name" >/dev/null
    fi
fi
GUEST
ssh "${ssh_args[@]}" "$guest_host" \
    "cd /opt/vemu && sudo env INSTANCE_NAME='$name' APK_GUEST_PATH='$apk_guest_path' docker compose --env-file profiles/$profile/profile.env $compose_files up -d --force-recreate"

booted=0
for _ in {1..90}; do
    if [[ "$(ssh "${ssh_args[@]}" "$guest_host" \
        "sudo docker exec '$name' getprop sys.boot_completed" 2>/dev/null | tr -d '\r')" = 1 ]]; then
        booted=1
        break
    fi
    sleep 2
done
test "$booted" = 1 || { printf 'Android did not finish booting\n' >&2; exit 1; }
if [[ -n "$apk_guest_path" ]]; then
    ssh "${ssh_args[@]}" "$guest_host" "sudo docker exec '$name' pm install -r /data/local/tmp/app.apk"
fi

renderer="$(ssh "${ssh_args[@]}" "$guest_host" \
    "sudo docker exec '$name' dumpsys SurfaceFlinger" | grep '^GLES:' | head -1)"
[[ "$renderer" == *'virgl ('* && "$renderer" == *'Apple'* ]] || {
    printf 'Unexpected renderer: %s\n' "$renderer" >&2
    exit 1
}
adb disconnect 127.0.0.1:5556 >/dev/null 2>&1 || true
adb_ready=0
for _ in {1..15}; do
    adb connect 127.0.0.1:5556 >/dev/null 2>&1 || true
    if [[ "$(adb -s 127.0.0.1:5556 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]]; then
        adb_ready=1
        break
    fi
    sleep 2
done
test "$adb_ready" = 1 || { printf 'ADB did not become ready\n' >&2; exit 1; }
test "$(adb -s 127.0.0.1:5556 shell getprop ro.product.device | tr -d '\r')" = "$name" || {
    printf 'Android device name did not match %s\n' "$name" >&2
    exit 1
}
printf '%s\n' "$name" > "$gpu_dir/active-name"
printf 'Name: %s\nProfile: %s\n%s\nOpen Android: scrcpy -s 127.0.0.1:5556\n' "$name" "$profile" "$renderer"
