#!/usr/bin/env python3
"""Derive mountable property files from the Redroid 16 image originals."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[4] / "profiles"
PROFILES = {
    # Observed device diagnostic: https://github.com/appsfolder/livebridge/issues/42
    "s25-ultra": {
        "brand": "samsung",
        "manufacturer": "samsung",
        "model": "SM-S938B",
        "device": "pa3q",
        "name": "pa3qxxx",
        "fingerprint": "samsung/pa3qxxx/pa3q:16/BP2A.250605.031.A3/S938BXXS9BZCH_OXM9BZCH:user/release-keys",
        "build_id": "BP2A.250605.031.A3",
        "incremental": "S938BXXS9BZCH_OXM9BZCH",
        "display_id": "BP2A.250605.031.A3.S938BXXS9BZCH",
    },
    # Observed device diagnostic: https://github.com/google/filament/issues/9918
    "pixel-10-pro": {
        "brand": "google",
        "manufacturer": "Google",
        "model": "Pixel 10 Pro",
        "device": "blazer",
        "name": "blazer",
        "fingerprint": "google/blazer/blazer:16/BD3A.251105.010.E1/14337626:user/release-keys",
        "build_id": "BD3A.251105.010.E1",
        "incremental": "14337626",
        "display_id": "14337626",
    },
}


def rewrite(base: str, partition: str, identity: dict[str, str]) -> str:
    build_prefix = f"ro.{partition}.build."
    overrides = {
        f"{build_prefix}fingerprint": identity["fingerprint"],
        f"{build_prefix}id": identity["build_id"],
        f"{build_prefix}tags": "release-keys",
        f"{build_prefix}type": "user",
        f"{build_prefix}version.incremental": identity["incremental"],
    }
    if partition == "system":
        overrides.update({
            "ro.build.id": identity["build_id"],
            "ro.build.display.id": identity["display_id"],
            "ro.build.version.incremental": identity["incremental"],
            "ro.build.type": "user",
            "ro.build.tags": "release-keys",
            "ro.build.flavor": f"{identity['name']}-user",
            "ro.build.product": identity["device"],
            "ro.build.description": (
                f"{identity['name']}-user 16 {identity['build_id']} "
                f"{identity['incremental']} release-keys"
            ),
        })
    output = []
    for line in base.splitlines():
        key, separator, _ = line.partition("=")
        parts = key.split(".")
        if separator and len(parts) == 4 and parts[:2] == ["ro", "product"] and parts[-1] in identity:
            line = f"{key}={identity[parts[-1]]}"
        elif separator and key in overrides:
            line = f"{key}={overrides[key]}"
        output.append(line)
    if partition == "system":
        output.append(f"ro.build.fingerprint={identity['fingerprint']}")
    return "\n".join(output) + "\n"


for profile, identity in PROFILES.items():
    for partition in ("system", "vendor", "product", "odm", "system_ext", "vendor_dlkm"):
        source = (ROOT / "base" / f"{partition}.build.prop").read_text()
        (ROOT / profile / f"{partition}.build.prop").write_text(rewrite(source, partition, identity))
