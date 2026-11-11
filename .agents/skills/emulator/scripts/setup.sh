#!/usr/bin/env bash
# Prepare a dedicated Colima seed disk and a locally built GPU QEMU runtime.
# Remote shell variables intentionally expand in the guest.
# shellcheck disable=SC2016
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
gpu_dir="${VEMU_HOME:-$HOME/.local/share/vemu}"
seed_profile=vemu-qemu-seed
qemu_source="$gpu_dir/macports/bin/qemu-system-aarch64"
qemu_runtime="$gpu_dir/qemu-system-aarch64"
entitlements="$script_dir/../assets/gpu-entitlements.plist"

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    printf 'vemu requires an Apple Silicon Mac\n' >&2
    exit 1
}
command -v brew >/dev/null || { printf 'Install Homebrew first: https://brew.sh\n' >&2; exit 1; }
command -v clang >/dev/null || { printf 'Install Xcode Command Line Tools: xcode-select --install\n' >&2; exit 1; }

if ! command -v colima >/dev/null; then brew install colima; fi
if ! command -v docker >/dev/null; then brew install docker; fi
if ! command -v adb >/dev/null; then brew install android-platform-tools; fi

mkdir -p "$gpu_dir"
chmod 700 "$gpu_dir"
if [[ ! -x "$qemu_source" ]]; then
    "$script_dir/build-qemu.sh"
fi
[[ -x "$qemu_source" ]] || { printf 'QEMU build is missing: %s\n' "$qemu_source" >&2; exit 1; }
if [[ ! -x "$qemu_runtime" || "$qemu_source" -nt "$qemu_runtime" || "$entitlements" -nt "$qemu_runtime" ]]; then
    rm -f "$qemu_runtime.tmp"
    cp "$qemu_source" "$qemu_runtime.tmp"
    xattr -c "$qemu_runtime.tmp"
    codesign --force --sign - --entitlements "$entitlements" "$qemu_runtime.tmp" >/dev/null
    mv "$qemu_runtime.tmp" "$qemu_runtime"
fi
codesign --verify --strict "$qemu_runtime"

if [[ -f "$gpu_dir/disk.raw" && -f "$gpu_dir/datadisk.qcow2" && -f "$gpu_dir/cidata.iso" &&
      -f "$gpu_dir/ssh_key" ]]; then
    printf 'Guest disks, cloud-init ISO, and SSH key already exist in %s\n' "$gpu_dir"
    exit 0
fi
for existing in disk.raw datadisk.qcow2 cidata.iso ssh_key; do
    [[ ! -e "$gpu_dir/$existing" ]] || {
        printf 'Incomplete guest runtime in %s; move existing guest files aside before setup\n' "$gpu_dir" >&2
        exit 1
    }
done
[[ "${VEMU_GUEST_USER:-$USER}" == "$USER" ]] || {
    printf 'Automatic setup uses the current Mac username; unset VEMU_GUEST_USER or provide a prepared guest\n' >&2
    exit 1
}

printf 'Preparing dedicated Colima profile %s (first run can take several minutes)...\n' "$seed_profile"
PATH="$gpu_dir/macports/bin:$PATH" colima start "$seed_profile" --arch aarch64 --vm-type qemu \
    --cpus 4 --memory 6 --disk 30 --root-disk 30 \
    --mount none --activate=false --ssh-config=false
colima -p "$seed_profile" ssh -- sudo sh -s < "$script_dir/setup-guest.sh"

ssh-keygen -q -t ed25519 -N '' -f "$gpu_dir/ssh_key"
chmod 600 "$gpu_dir/ssh_key"
cat "$gpu_dir/ssh_key.pub" | colima -p "$seed_profile" ssh -- sh -c \
    'mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" && touch "$HOME/.ssh/authorized_keys" && read -r key && { grep -qxF "$key" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"; } && chmod 600 "$HOME/.ssh/authorized_keys"'

guest_mac="$(colima -p "$seed_profile" ssh -- cat /sys/class/net/eth0/address | tr -d '\r\n')"
[[ "$guest_mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || {
    printf 'Could not determine guest eth0 MAC: %s\n' "$guest_mac" >&2
    exit 1
}
printf '%s\n' "$guest_mac" > "$gpu_dir/guest-mac"

seed_disk="$HOME/.colima/_lima/colima-$seed_profile/disk"
seed_datadisk="$HOME/.colima/_lima/_disks/colima-$seed_profile/datadisk"
seed_cidata="$HOME/.colima/_lima/colima-$seed_profile/cidata.iso"
colima -p "$seed_profile" ssh -- sudo sync
colima stop "$seed_profile" &
stop_pid=$!
for _ in {1..45}; do
    if ! kill -0 "$stop_pid" 2>/dev/null; then
        wait "$stop_pid"
        break
    fi
    sleep 1
done
if kill -0 "$stop_pid" 2>/dev/null; then
    printf 'Colima did not shut down within 45 seconds; stopping the synchronized seed VM now...\n' >&2
    colima stop "$seed_profile" --force
    wait "$stop_pid" || true
fi
test -f "$seed_disk"
test -f "$seed_datadisk"
test -f "$seed_cidata"
printf 'Copying stopped Colima root disk to %s/disk.raw...\n' "$gpu_dir"
if ! /bin/cp -c "$seed_disk" "$gpu_dir/disk.raw"; then
    /bin/cp "$seed_disk" "$gpu_dir/disk.raw"
fi
if ! /bin/cp -c "$seed_datadisk" "$gpu_dir/datadisk.qcow2"; then
    /bin/cp "$seed_datadisk" "$gpu_dir/datadisk.qcow2"
fi
if ! /bin/cp -c "$seed_cidata" "$gpu_dir/cidata.iso"; then
    /bin/cp "$seed_cidata" "$gpu_dir/cidata.iso"
fi
printf 'Setup complete. The Colima seed remains stopped; vemu boots its disk copy.\n'
