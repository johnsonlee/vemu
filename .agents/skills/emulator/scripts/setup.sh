#!/usr/bin/env bash
# Prepare a dedicated Colima seed disk, then boot its copy with UTM QEMU.
# Remote shell variables intentionally expand in the guest.
# shellcheck disable=SC2016
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
gpu_dir="${VEMU_HOME:-$HOME/.local/share/vemu}"
seed_profile=vemu-seed
utm_version=4.6.5
qemu_relative=Contents/Frameworks/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu

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
if [[ ! -f "$gpu_dir/UTM.app/$qemu_relative" ]]; then
    if [[ -L "$gpu_dir/UTM.app" && ! -e "$gpu_dir/UTM.app" ]]; then
        rm "$gpu_dir/UTM.app"
    fi
    installed_utm_version=
    if [[ -f /Applications/UTM.app/Contents/Info.plist ]]; then
        installed_utm_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/UTM.app/Contents/Info.plist 2>/dev/null || true)"
    fi
    if [[ "$installed_utm_version" == "$utm_version" && -f "/Applications/UTM.app/$qemu_relative" ]]; then
        ln -s /Applications/UTM.app "$gpu_dir/UTM.app"
    else
        printf 'Downloading UTM %s from its official GitHub release...\n' "$utm_version"
        temporary_dir="$(mktemp -d "$gpu_dir/utm-download.XXXXXX")"
        mounted=0
        cleanup() {
            if ((mounted)); then hdiutil detach "$temporary_dir/mount" -quiet || true; fi
            rm -rf "$temporary_dir"
        }
        trap cleanup EXIT
        curl --fail --location --retry 3 \
            "https://github.com/utmapp/UTM/releases/download/v${utm_version}/UTM.dmg" \
            --output "$temporary_dir/UTM.dmg"
        mkdir "$temporary_dir/mount"
        hdiutil attach -readonly -nobrowse -quiet -mountpoint "$temporary_dir/mount" "$temporary_dir/UTM.dmg"
        mounted=1
        ditto "$temporary_dir/mount/UTM.app" "$gpu_dir/UTM.app"
        test -f "$gpu_dir/UTM.app/$qemu_relative"
        cleanup
        trap - EXIT
    fi
fi
codesign --verify --deep --strict "$gpu_dir/UTM.app"

if [[ -f "$gpu_dir/disk.raw" && -f "$gpu_dir/ssh_key" ]]; then
    printf 'Guest disk and SSH key already exist in %s\n' "$gpu_dir"
    exit 0
fi
[[ ! -e "$gpu_dir/disk.raw" ]] || {
    printf 'A guest disk already exists, but its SSH key is missing: %s\n' "$gpu_dir" >&2
    exit 1
}
[[ ! -e "$gpu_dir/ssh_key" ]] || {
    printf 'An SSH key already exists, but its guest disk is missing: %s\n' "$gpu_dir" >&2
    exit 1
}
[[ "${VEMU_GUEST_USER:-$USER}" == "$USER" ]] || {
    printf 'Automatic setup uses the current Mac username; unset VEMU_GUEST_USER or provide a prepared guest\n' >&2
    exit 1
}

printf 'Preparing dedicated Colima profile %s (first run can take several minutes)...\n' "$seed_profile"
colima start "$seed_profile" --arch aarch64 --vm-type vz \
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
colima stop "$seed_profile"
test -f "$seed_disk"
printf 'Copying stopped Colima root disk to %s/disk.raw...\n' "$gpu_dir"
if ! /bin/cp -c "$seed_disk" "$gpu_dir/disk.raw"; then
    /bin/cp "$seed_disk" "$gpu_dir/disk.raw"
fi
printf 'Setup complete. The Colima seed remains stopped; vemu boots its disk copy.\n'
