---
name: emulator
description: Maintain and run this project's macOS GPU accelerated Redroid emulator, including QEMU/VirGL startup, Docker Compose device profiles, Android properties, and graphics verification. Use for emulator work in this repository.
---

# vemu emulator

Use this skill for work on the emulator in this repository. Read the root `README.md` and `compose.yaml` for the current setup. The launch, stop, guest provisioning, and profile generation helpers live in this skill's `scripts/` directory. The QEMU loader source is in `src/`, and its macOS signing entitlements are in `assets/`.

## Runtime invariants

- The Mac launches an ARM64 Linux guest with UTM's QEMU and `virtio-gpu-gl-pci`. Redroid runs in that guest through Docker Compose and uses `androidboot.redroid_gpu_mode=host` with `/dev/dri/renderD128`. A successful boot alone does not prove GPU rendering.
- The guest must bind mount the **real Binderfs device nodes** to `/dev/binder`, `/dev/hwbinder`, and `/dev/vndbinder` before starting the container. Docker `--privileged` or recreated device nodes alone are insufficient.
- The QEMU disk, UTM application, SSH key, and Android data volumes are local runtime assets. Keep them out of Git. On first start, `scripts/setup.sh` downloads pinned UTM 4.6.5 when needed, creates a dedicated Colima `vz` seed, provisions the guest, stops Colima, and copies its root disk. QEMU must use the seed guest's saved NIC MAC to retain its network configuration. Treat guest provisioning and host forwarding settings as part of the runtime contract when changing QEMU or networking.
- Each device profile has its own Android data volume; `default` links to `pixel-10-pro` and shares that volume. Preserve existing volumes when switching or stopping profiles; delete a volume only when the user explicitly asks to reset that profile's data.

## Device profiles

The root `profiles/<name>/profile.env` selects screen dimensions, logical DPI, and data volume. Six read-only mapped property files carry the model, brand, manufacturer, device, and product name for `system`, `vendor`, `product`, `odm`, `system_ext`, and `vendor_dlkm`. Android derives top-level `ro.product.*` values from these partitions; changing only `/system/build.prop` or `/vendor/build.prop` leaves the top-level identity inconsistent.

When adding or updating a profile, keep the baseline files in `profiles/base/` aligned with the actual Redroid image, edit the profile definitions in `scripts/generate-profiles.py`, generate the mapped files, and validate both the Compose config and Android's post-boot `getprop` output. Use sourced device specifications for model, native screen size, and any reported firmware fingerprint. Android logical DPI is a separate configuration choice from physical panel PPI. A reported fingerprint and `http.agent` can resemble a device while the actual firmware, patch contents, and attestation remain Redroid; document this distinction.

Android's Java `http.agent` is derived from version, model, and build ID at process startup; verify it with `System.getProperty("http.agent")` in a Java process. The system WebView's default User-Agent may include the profile's model and build ID, but its WebView version comes from the running image. Apps can override User-Agent themselves, and newer WebView versions may reduce device tokens. Check the actual UA with `WebSettings.getDefaultUserAgent()` or the target app's network/WebView output when UA matters; do not infer an exact real-phone WebView UA from `build.prop` alone.

## Run and verify

From the repository root, use `./.agents/skills/emulator/scripts/emulator.sh start --profile default --name vemu` and `./.agents/skills/emulator/scripts/emulator.sh stop`. First start prepares the runtime automatically; `emulator.sh setup` prepares it without starting Android. `--profile` chooses the device configuration; `--name` sets the Docker container name and Android `ro.product.device`, which appears as `device:` in `adb devices -l`. The ADB serial remains `127.0.0.1:5556`. `--apk /path/app.apk` stages the file once in the guest by content hash, bind mounts it read-only through `compose.apk.yaml`, and runs `pm install` inside the container; it does not send the APK through ADB. The start script syncs Compose and profiles to the guest. After a change, inspect the guest's Compose status and verify `sys.boot_completed=1`, the chosen model, the requested device name, `wm size`, `wm density`, and SurfaceFlinger's `GLES:` line. A host GPU result should name VirGL and the Apple renderer. For app compatibility, launch the affected APK and inspect its rendered frames or screenshot. Treat this as functional evidence, not a performance benchmark.
