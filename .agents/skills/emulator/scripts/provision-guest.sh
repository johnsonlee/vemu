#!/bin/sh
# Run as root in the dedicated QEMU guest before starting Redroid.
set -eu

modprobe binder_linux
modprobe ashmem_linux
test -c /dev/ashmem
test -c /dev/dri/renderD128

mkdir -p /dev/binderfs
if ! mountpoint -q /dev/binderfs; then
    mount -t binder binder /dev/binderfs
fi

# Binderfs devices must be bind mounted. Recreating their major/minor with
# mknod produces nodes that fail to open with ENXIO.
for name in binder hwbinder vndbinder; do
    target="/dev/$name"
    if ! mountpoint -q "$target"; then
        test -e "$target" || touch "$target"
        mount --bind "/dev/binderfs/$name" "$target"
    fi
    chmod 0666 "$target"
done
chmod 0666 /dev/ashmem

# The cloned Lima disk has the old VM's DNS address; QEMU user networking
# provides DNS at 10.0.2.3.
printf 'nameserver 10.0.2.3\n' > /etc/resolv.conf
