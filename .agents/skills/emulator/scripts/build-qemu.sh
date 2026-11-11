#!/usr/bin/env bash
# Build a GPU-enabled QEMU in VEMU_HOME without administrator privileges.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: %s [--jobs N]\n' "$0"
    exit 0
fi

jobs="$(sysctl -n hw.ncpu)"
while (($#)); do
    case "$1" in
        --jobs)
            (($# >= 2)) || { printf 'Missing value for --jobs\n' >&2; exit 2; }
            jobs="$2"
            shift 2 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid job count: %s\n' "$jobs" >&2; exit 2; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    printf 'vemu requires an Apple Silicon Mac\n' >&2
    exit 1
}

runtime="${VEMU_HOME:-$HOME/.local/share/vemu}"
build_root="$runtime/qemu-build"
prefix="$runtime/macports"
port="$prefix/bin/port"
base_version=2.12.7
base_sha256=6a3730de846bb78e3fb4ced2ed8d13f777e6aca2ab2f59cade9ca0d549ccc4ba
source_dir="$build_root/MacPorts-$base_version"
archive="$build_root/MacPorts-$base_version.tar.bz2"
mkdir -p "$build_root"
chmod 700 "$runtime"

# MacPorts acts only as a source-build orchestrator in this private prefix.
# Its no-root configuration never installs into /opt/local or asks for sudo.
if [[ ! -x "$port" ]]; then
    printf 'Bootstrapping rootless MacPorts %s for the QEMU build...\n' "$base_version"
    curl --fail --location --retry 3 \
        "https://github.com/macports/macports-base/releases/download/v${base_version}/MacPorts-${base_version}.tar.bz2" \
        --output "$archive"
    printf '%s  %s\n' "$base_sha256" "$archive" | shasum -a 256 -c -
    tar -xjf "$archive" -C "$build_root"
    (
        cd "$source_dir"
        native_path="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin"
        env PATH="$native_path" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib \
            ./configure --prefix="$prefix" --with-no-root-privileges \
            --without-startupitems --with-applications-dir="$prefix/Applications" \
            > "$build_root/macports-configure.log" 2>&1
        env PATH="$native_path" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib \
            make -j "$jobs" > "$build_root/macports-build.log" 2>&1
        env PATH="$native_path" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib \
            make install > "$build_root/macports-install.log" 2>&1
    ) || {
        printf 'MacPorts bootstrap failed; inspect %s/macports-*.log\n' "$build_root" >&2
        exit 1
    }
fi

export PATH="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin"
printf 'Syncing MacPorts source recipes...\n'
"$port" sync
# ANGLE defaults to Apple's desktop OpenGL in the upstream MacPorts recipe.
# Its Metal backend is required for a headless EGL context on macOS.
angle_portfile="$prefix/var/macports/sources/rsync.macports.org/macports/release/tarballs/ports/graphics/angle/Portfile"
python3 - "$angle_portfile" <<'PY'
from pathlib import Path
import sys

portfile = Path(sys.argv[1])
text = portfile.read_text()
if text.count('angle_enable_metal=false') == 1:
    portfile.write_text(text.replace('angle_enable_metal=false', 'angle_enable_metal=true'))
elif text.count('angle_enable_metal=true') != 1:
    raise SystemExit('Unexpected ANGLE Portfile; cannot enable Metal')
PY
# Upstream QEMU exposes egl-headless on macOS but never initializes an EGL
# display there. The patch selects ANGLE's Metal EGL display explicitly.
qemu_port_dir="$prefix/var/macports/sources/rsync.macports.org/macports/release/tarballs/ports/emulators/qemu"
cp "$script_dir/../assets/qemu-macos-egl.patch" "$qemu_port_dir/files/patch-qemu-macos-egl.diff"
if ! grep -Fqx 'patchfiles-append patch-qemu-macos-egl.diff' "$qemu_port_dir/Portfile"; then
    printf '\npatchfiles-append patch-qemu-macos-egl.diff\n' >> "$qemu_port_dir/Portfile"
fi
virgl_port_dir="$prefix/var/macports/sources/rsync.macports.org/macports/release/tarballs/ports/graphics/virglrenderer"
mkdir -p "$virgl_port_dir/files"
cp "$script_dir/../assets/virglrenderer-macos-egl.patch" "$virgl_port_dir/files/patch-macos-external-egl.diff"
if ! grep -Fqx 'patchfiles-append patch-macos-external-egl.diff' "$virgl_port_dir/Portfile"; then
    printf '\npatchfiles-append patch-macos-external-egl.diff\n' >> "$virgl_port_dir/Portfile"
fi
# Apple's Xcode 15 Clang does not accept GN's C++23 spelling and rejects some
# QEMU 11.1.3 ARM initializers. Use a user-installed Homebrew LLVM for both.
if ! printf 'int main() {}\n' | /usr/bin/clang++ -std=c++23 -x c++ -fsyntax-only - >/dev/null 2>&1; then
    command -v brew >/dev/null || {
        printf 'Homebrew is required to install a C++23 compiler for GN\n' >&2
        exit 1
    }
    if ! brew list --versions llvm >/dev/null 2>&1; then
        brew install llvm
    fi
    llvm_prefix="$(brew --prefix llvm)"
    "$llvm_prefix/bin/clang++" -std=c++23 -x c++ -fsyntax-only /dev/null || {
        printf 'Homebrew LLVM does not support C++23\n' >&2
        exit 1
    }
    gn_portfile="$prefix/var/macports/sources/rsync.macports.org/macports/release/tarballs/ports/devel/gn/Portfile"
    python3 - "$gn_portfile" "$llvm_prefix" <<'PY'
from pathlib import Path
import sys

portfile = Path(sys.argv[1])
llvm = Path(sys.argv[2])
text = portfile.read_text()
needle = 'compiler.cxx_standard   2023\n'
if text.count(needle) != 1:
    raise SystemExit('Unexpected GN Portfile; cannot apply the local C++23 compiler override')
override = (f'configure.cc        {llvm}/bin/clang\n'
            f'configure.cxx       {llvm}/bin/clang++\n')
if override not in text:
    portfile.write_text(text.replace(needle, needle + override))
PY
    qemu_portfile="$prefix/var/macports/sources/rsync.macports.org/macports/release/tarballs/ports/emulators/qemu/Portfile"
    python3 - "$qemu_portfile" "$llvm_prefix" <<'PY'
from pathlib import Path
import sys

portfile = Path(sys.argv[1])
llvm = Path(sys.argv[2])
text = portfile.read_text()
needle = 'configure.args          --cpu=${host_cpu} \\\n'
if text.count(needle) != 1:
    raise SystemExit('Unexpected QEMU Portfile; cannot apply the local compiler override')
override = (f'configure.cc           {llvm}/bin/clang\n'
            f'configure.cxx          {llvm}/bin/clang++\n')
if override not in text:
    portfile.write_text(text.replace(needle, override + needle))
PY
fi
printf 'Building ANGLE, VirGL, SPICE, and QEMU in %s...\n' "$prefix"
"$port" -N install libepoxy +egl +quartz -x11
"$port" -N install virglrenderer +quartz -x11
"$port" -N install qemu +gl +spice +target_arm -vnc -cocoa -curses -usb -target_i386 -target_x86_64

active_qemu="$("$port" installed qemu | grep '(active)' || true)"
[[ "$active_qemu" == *+gl* && "$active_qemu" == *+spice* &&
   "$active_qemu" == *+target_arm* && "$active_qemu" != *+vnc* ]] || {
    printf 'QEMU is not active with the required GPU/SPICE variants and VNC disabled: %s\n' "$active_qemu" >&2
    exit 1
}

qemu="$prefix/bin/qemu-system-aarch64"
[[ -x "$qemu" ]] || { printf 'QEMU build did not produce %s\n' "$qemu" >&2; exit 1; }
version="$("$qemu" --version | sed -n '1s/^QEMU emulator version \([0-9][0-9.]*\).*/\1/p')"
python3 - "$version" <<'PY'
import sys
try:
    version = tuple(map(int, sys.argv[1].split('.')[:3]))
except ValueError:
    version = ()
if version < (11, 1, 3):
    raise SystemExit(f'QEMU 11.1.3 or newer is required; found {sys.argv[1]!r}')
PY
"$qemu" -device help | grep -q 'virtio-gpu-gl-pci' || {
    printf 'Built QEMU lacks virtio-gpu-gl-pci\n' >&2
    exit 1
}
"$port" installed qemu virglrenderer angle libepoxy spice-server > "$build_root/build-manifest.txt"
shasum -a 256 "$qemu" >> "$build_root/build-manifest.txt"
printf 'Built %s from checked MacPorts source recipes\n' "$("$qemu" --version | head -1)"
