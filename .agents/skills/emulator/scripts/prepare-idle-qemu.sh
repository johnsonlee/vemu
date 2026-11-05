#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
skill_dir="$(dirname "$script_dir")"
runtime="${VEMU_HOME:-$HOME/.local/share/vemu}"
original="$runtime/UTM.app/Contents/Frameworks/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu"
out_dir="$runtime/hvf-idle"
patched="$out_dir/qemu-aarch64-softmmu"
interposer="$out_dir/critical-pselect.dylib"

[[ -f "$original" ]] || { printf 'Missing UTM QEMU: %s\n' "$original" >&2; exit 1; }
mkdir -p "$out_dir"

if [[ ! -f "$patched" || "$original" -nt "$patched" ||
      "$script_dir/patch-qemu-wfi.py" -nt "$patched" ]]; then
    xcrun lipo -thin arm64 "$original" -output "$out_dir/qemu-original.tmp"
    python3 "$script_dir/patch-qemu-wfi.py" \
        --input "$out_dir/qemu-original.tmp" --output "$out_dir/qemu-patched.tmp"
    codesign --force --sign - "$out_dir/qemu-patched.tmp" >/dev/null
    mv "$out_dir/qemu-patched.tmp" "$patched"
    rm -f "$out_dir/qemu-original.tmp"
fi

if [[ ! -f "$interposer" || "$skill_dir/src/hvf-critical-pselect.c" -nt "$interposer" ]]; then
    clang -O2 -Wall -Wextra -dynamiclib -o "$out_dir/critical-pselect.tmp.dylib" \
        "$skill_dir/src/hvf-critical-pselect.c"
    codesign --force --sign - "$out_dir/critical-pselect.tmp.dylib" >/dev/null
    mv "$out_dir/critical-pselect.tmp.dylib" "$interposer"
fi

codesign --verify "$patched"
codesign --verify "$interposer"
