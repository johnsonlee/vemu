# vemu

[简体中文](README.zh.md) · [MIT License](LICENSE)

vemu runs Android 16 on Apple Silicon macOS with GPU-backed rendering. It starts an ARM64 Linux guest with UTM's QEMU, runs [Redroid](https://github.com/remote-android/redroid-doc) through Docker Compose, and sends Android OpenGL work through VirGL and ANGLE to the Mac GPU. Device profiles select Android properties and display settings.

> [!IMPORTANT]
> **Experimental setup.** First start downloads UTM and creates a dedicated Linux guest disk. The complete fresh setup has been verified on one M3 Max Mac; other Apple Silicon Macs and future guest kernels need testing. No performance benchmark is claimed.

On first start, vemu creates a dedicated [Colima](https://github.com/abiosoft/colima)/Lima ARM64 Ubuntu guest, prepares Docker, Binder/ashmem, and SSH, stops Colima, and copies its root disk. `emulator.sh` then boots that copy directly with UTM's QEMU to expose the VirGL render device. Colima prepares the disk; it does not run alongside vemu.

## How it works

```text
Android app → Redroid container → Linux virtio-gpu/VirGL
            → UTM QEMU (HVF) → ANGLE/Metal → Mac GPU

Mac adb :5556 → QEMU port forward → guest Docker :5555 → Android adbd
```

The Mac runs one QEMU guest and one active Android container at a time. Docker Compose runs **inside the Linux guest**. The launch script bind mounts real Binderfs nodes into the container, then checks Android boot and the SurfaceFlinger renderer before reporting success.

The repository includes [`compose.yaml`](compose.yaml) for Redroid and [`compose.apk.yaml`](compose.apk.yaml) for the optional APK bind mount. `emulator.sh start` copies these files and the selected profiles into `/opt/vemu/` in the guest, then runs `docker compose up -d --force-recreate` there. The Mac script manages QEMU; Compose manages the Android container.

The setup script stops the `vemu-seed` Colima profile before copying its disk. It retains the stopped seed profile for troubleshooting. vemu uses a separate disk copy, so Colima never writes to vemu's active disk.

## Requirements

| Location | Requirement |
| --- | --- |
| Mac | Apple Silicon macOS, [Homebrew](https://brew.sh/), Xcode Command Line Tools (`clang`), Python 3, and SSH. [scrcpy](https://github.com/Genymobile/scrcpy) is optional for a display window. |
| First start | Network access and free disk space for a 30 GiB guest root disk, its copy, UTM, Linux packages, and the Redroid image. The script installs missing Colima, Docker CLI, and [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) with Homebrew. |
| Runtime directory | `~/.local/share/vemu/` holds the downloaded or linked UTM 4.6.5 app, `disk.raw`, a dedicated SSH key, and the guest NIC MAC. These are created automatically. |

The tested combination is Apple M3 Max, macOS 14.3, UTM 4.6.5 / QEMU 9.1.2, and `redroid/redroid:16.0.0_64only-latest`. UTM, the guest disk, SSH keys, APKs, and Android data volumes are not committed to Git. The launch script uses 4 vCPUs and 6 GiB guest RAM.

`VEMU_HOME` can point to a different runtime directory. `VEMU_GUEST_USER` can select another username for a manually prepared guest; automated setup uses the current Mac username. These are environment variables, not CLI options.

## Quick start

1. Install [Homebrew](https://brew.sh/) and Xcode Command Line Tools (`xcode-select --install`) if needed. Clone the repository and start the default Pixel 10 Pro profile:

   ```bash
   git clone https://github.com/johnsonlee/vemu.git
   cd vemu
   ./.agents/skills/emulator/scripts/emulator.sh start
   ```

   The first start downloads [UTM 4.6.5 from its official GitHub release](https://github.com/utmapp/UTM/releases/tag/v4.6.5) unless that version is already in `/Applications`, creates and prepares the Colima seed, copies its stopped root disk, pulls Redroid, and starts Android. It may take several minutes. Later starts reuse the disk.

2. Connect to the Android display, if desired:

   ```bash
   ./.agents/skills/emulator/scripts/emulator.sh view
   ```

3. Stop the guest without deleting Android data:

   ```bash
   ./.agents/skills/emulator/scripts/emulator.sh stop
   ```

Run `emulator.sh setup` to prepare the runtime without starting Android. The start command compiles and signs its small QEMU loader on first use, provisions Binderfs in the guest, syncs Compose and profile files, creates the selected data volume, and waits for Android and VirGL. SSH listens on Mac `127.0.0.1:2223`; ADB listens on Mac `127.0.0.1:5556`.

## CLI

```text
emulator.sh start [--profile PROFILE] [--name NAME] [--apk /path/to/app.apk] [--fps 1-120]
emulator.sh stop [--name NAME]
emulator.sh setup
emulator.sh view [--secure]
```

| Option | Effect |
| --- | --- |
| `--profile` | Selects `default`, `pixel-10-pro`, or `s25-ultra`. `default` is a symlink to `pixel-10-pro`. |
| `--name` | Sets the Docker container name and Android `ro.product.device`, shown as `device:` by `adb devices -l`. Default: `vemu`. It does **not** change the ADB serial (`127.0.0.1:5556`) or the profile's model. |
| `--apk` | Installs an APK during `start`. The script copies it from the Mac to the Linux guest once per SHA-256 hash, bind mounts it read-only as `/data/local/tmp/app.apk`, and runs `pm install -r` inside the container. It does not copy the APK through ADB. |
| `--fps` | Sets Redroid's display refresh cap. Default: 15. Use `--fps 30` for smoother interaction at higher idle CPU cost. |
| `view --secure` | Uses a patched scrcpy 4.1 server running as Android's `system` user to mirror activities with `FLAG_SECURE`. Requires scrcpy 4.1 on the Mac. |

In one high-wakeup episode on an M3 Max, the 15 FPS cap lowered QEMU host CPU from roughly 100% to 10%. The high usage is intermittent, and 30 FPS can also be quiet; the cap is a mitigation, not a root fix. It limits animation smoothness.

Android's `FLAG_SECURE` normally makes protected activities black in scrcpy. The optional `view --secure` command uses a secure virtual display on this rooted Redroid image; a test activity with `FLAG_SECURE` was black in stock scrcpy and visible through this command. It mirrors protected content to the Mac, so use it only with apps and data you intend to display. This is separate from DRM protected video. The bundled server's source, patch, build instructions, and Apache 2.0 license are in [assets](.agents/skills/emulator/assets/scrcpy-secure-README.md).

Examples:

```bash
./.agents/skills/emulator/scripts/emulator.sh start --profile s25-ultra --name s25-test
./.agents/skills/emulator/scripts/emulator.sh start --apk /absolute/path/app.apk
adb devices -l
```

The first APK transfer from the Mac into the guest is still necessary because this QEMU setup has no shared filesystem. Reusing the same APK skips that transfer.

## Device profiles

| Profile | Reported model | Display pixels | Logical DPI | Docker data volume |
| --- | --- | ---: | ---: | --- |
| `default` → `pixel-10-pro` | Pixel 10 Pro | 1280 × 2856 | 480 | `vemu-pixel-10-pro-data` |
| `s25-ultra` | Galaxy S25 Ultra (`SM-S938B`) | 1440 × 3120 | 480* | `vemu-s25-ultra-data` |

Display pixel counts come from [Google](https://store.google.com/product/pixel_10_pro_specs?hl=en-US) and [Samsung](https://www.samsung.com/co/business/smartphones/galaxy-s/galaxy-s25-ultra-titanium-silverblue-1tb-sm-s938bzbultc/). *The S25 Ultra logical DPI is a profile choice, not a verified factory default or the panel's physical PPI. The Pixel 10 Pro value follows an Android Virtual Device baseline, not a measured retail device.

Each profile has a `profile.env` file and six complete, read-only mapped `build.prop` files for `system`, `vendor`, `product`, `odm`, `system_ext`, and `vendor_dlkm`. Android derives top-level `ro.product.*` values from these partitions. Profile data volumes are separate; `default` and `pixel-10-pro` share one volume because they are the same profile.

The generated property files also set a reported build fingerprint and matching build ID for each profile. The Pixel 10 Pro values come from a [Pixel 10 Pro device report](https://github.com/google/filament/issues/9918), and the Galaxy S25 Ultra values from an [SM-S938B device diagnostic](https://github.com/appsfolder/livebridge/issues/42). Android generates Java's `http.agent` from the Android version, model, and build ID at process startup; this is distinct from a WebView or browser User-Agent ([AOSP RuntimeInit](https://android.googlesource.com/platform/frameworks/base/+/b9c98916b11932e7e55849c9c69d116002671a0e/core/java/com/android/internal/os/RuntimeInit.java)). On the tested image, the default profile reports `Dalvik/2.1.0 (Linux; U; Android 16; Pixel 10 Pro Build/BD3A.251105.010.E1)`.

To edit or add a profile, update `PROFILES` in [`generate-profiles.py`](.agents/skills/emulator/scripts/generate-profiles.py), provide its `profile.env`, regenerate the property files, and review the diff:

```bash
python3 .agents/skills/emulator/scripts/generate-profiles.py
```

The checked-in base property files came from the Redroid 16 image used in testing. The image tag ends in `latest` and may change; review and refresh the base files and generated profiles before upgrading the image.

## Verify a running instance

```bash
adb devices -l
adb -s 127.0.0.1:5556 shell getprop sys.boot_completed
adb -s 127.0.0.1:5556 shell getprop ro.product.model
adb -s 127.0.0.1:5556 shell getprop ro.product.device
adb -s 127.0.0.1:5556 shell getprop ro.build.fingerprint
adb -s 127.0.0.1:5556 shell getprop ro.build.id
adb -s 127.0.0.1:5556 shell wm size
adb -s 127.0.0.1:5556 shell wm density
adb -s 127.0.0.1:5556 shell dumpsys SurfaceFlinger | grep '^GLES:'
```

Expect `sys.boot_completed=1`, the selected model and screen settings, and a renderer containing `virgl` and `Apple`. On the tested M3 Max, SurfaceFlinger reported `virgl (ANGLE (Apple, Apple M3 Max, OpenGL 4.1 Metal - 88))`. This verifies the graphics path, not frame rate or performance.

## Known limitations

- The setup path has been tested on one M3 Max Mac. It relies on Colima's current ARM64 Ubuntu kernel and a pinned ashmem DKMS source; a different guest kernel may need updated module support. No guest image is distributed.
- The Redroid container runs with Docker `privileged` access and mapped Binder devices inside the dedicated guest.
- Profiles change reported identity strings, including the fingerprint and Java `http.agent`, plus display properties. The actual firmware, security patch contents, WebView version, and hardware remain Redroid. `--name` still overrides `ro.product.device` for ADB's `device:` field, even though the reported fingerprint contains the profile's device codename. Apps may override their own User-Agent; these profiles cannot provide genuine Samsung or Google firmware or device integrity attestation. See the [Android WebSettings API](https://developer.android.com/reference/android/webkit/WebSettings).
- GPU functionality has been checked on one Mac configuration. Other Apple Silicon Macs and guest kernels need verification.

## Contributing

Issues and pull requests are welcome. For runtime bugs, include the Mac model and macOS version, guest kernel and Docker Compose versions, selected profile, `adb devices -l`, and the SurfaceFlinger `GLES:` line. Remove private keys, APKs, account data, and other sensitive logs before attaching files. Run `shellcheck` on changed shell scripts and `docker compose config --quiet` for affected profiles; see the project [emulator skill](.agents/skills/emulator/SKILL.md) for runtime invariants.

## License

[MIT](LICENSE). UTM, Redroid, Android, and scrcpy are separate projects under their own licenses.
