#!/usr/bin/env python3
"""Derive mountable property files from the Redroid 16 image originals."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[4] / "profiles"
PROFILES = {
    "s25-ultra": ("samsung", "SM-S938B", "pa3q", "pa3q"),
    "pixel-10-pro": ("google", "Pixel 10 Pro", "blazer", "blazer"),
}


def rewrite(base: str, brand: str, model: str, device: str, name: str) -> str:
    values = {
        "brand": brand,
        "manufacturer": "samsung" if brand == "samsung" else "Google",
        "model": model,
        "device": device,
        "name": name,
    }
    output = []
    for line in base.splitlines():
        key, separator, _ = line.partition("=")
        parts = key.split(".")
        if separator and len(parts) == 4 and parts[:2] == ["ro", "product"] and parts[-1] in values:
            line = f"{key}={values[parts[-1]]}"
        output.append(line)
    return "\n".join(output) + "\n"


for profile, values in PROFILES.items():
    for partition in ("system", "vendor", "product", "odm", "system_ext", "vendor_dlkm"):
        source = (ROOT / "base" / f"{partition}.build.prop").read_text()
        (ROOT / profile / f"{partition}.build.prop").write_text(rewrite(source, *values))
