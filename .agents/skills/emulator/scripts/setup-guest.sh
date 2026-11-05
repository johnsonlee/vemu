#!/bin/sh
# Run as root in the dedicated Colima seed guest.
set -eu

if ! modinfo binder_linux >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends "linux-modules-extra-$(uname -r)"
fi
printf 'options binder_linux devices=binder,hwbinder,vndbinder\n' > /etc/modprobe.d/vemu-binder.conf
modprobe binder_linux

if ! modinfo ashmem_linux >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential dkms git zstd "linux-headers-$(uname -r)"

    revision=f55e1e7515a6dd5f8e0f9569ea79148c08f60816
    source_dir=/usr/local/src/redroid-modules
    mkdir -p "$source_dir"
    git -C "$source_dir" init -q
    git -C "$source_dir" fetch --depth=1 \
        https://github.com/remote-android/redroid-modules.git "$revision"
    git -C "$source_dir" checkout --detach "$revision"

    dkms_source=/usr/src/redroid-ashmem-f55e1e7
    mkdir -p "$dkms_source"
    for file in ashmem.c ashmem.h deps.c deps.h Makefile; do
        cp "$source_dir/ashmem/$file" "$dkms_source/$file"
    done
    cp -R "$source_dir/ashmem/uapi" "$dkms_source/"
    cat > "$dkms_source/dkms.conf" <<'DKMS'
PACKAGE_NAME="redroid-ashmem"
PACKAGE_VERSION="f55e1e7"
BUILT_MODULE_NAME[0]="ashmem_linux"
DEST_MODULE_LOCATION[0]="/updates/dkms"
MAKE[0]="make KDIR=/lib/modules/${kernelver}/build"
CLEAN="make clean KDIR=/lib/modules/${kernelver}/build"
AUTOINSTALL="yes"
DKMS
    dkms install -m redroid-ashmem -v f55e1e7 -k "$(uname -r)"
fi

printf 'binder_linux\nashmem_linux\n' > /etc/modules-load.d/vemu.conf
modprobe ashmem_linux
test -c /dev/ashmem
test "$(getconf PAGESIZE)" -eq 4096

if ! command -v sshd >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends openssh-server
fi
systemctl enable --now ssh
docker compose version
