# vemu

[简体中文](README.zh.md) · [MIT License](LICENSE)

vemu runs Android 16 on Apple Silicon macOS with GPU-backed rendering. It starts an ARM64 Linux guest with UTM's QEMU, runs [Redroid](https://github.com/remote-android/redroid-doc) through Docker Compose, and sends Android OpenGL work through VirGL and ANGLE to the Mac GPU. Device profiles select Android properties and display settings.

> [!IMPORTANT]
> **Experimental setup.** The repository does not build or distribute the Linux guest disk. A fresh clone will not start until you provide the preconfigured guest described below. The GPU path has been verified on one M3 Max Mac; no performance benchmark is claimed.

The tested `disk.raw` was cloned from a stopped [Colima](https://github.com/abiosoft/colima)/Lima ARM64 Ubuntu guest after Docker and Binder/ashmem support were set up there. `emulator.sh` then boots that copy directly with UTM's QEMU to expose the VirGL render device. Colima was used to prepare the disk; it is not part of the vemu runtime. Automating the Colima setup and disk handoff is still outstanding.

## How it works

```text
Android app → Redroid container → Linux virtio-gpu/VirGL
            → UTM QEMU (HVF) → ANGLE/Metal → Mac GPU

Mac adb :5556 → QEMU port forward → guest Docker :5555 → Android adbd
```

The Mac runs one QEMU guest and one active Android container at a time. Docker Compose runs **inside the Linux guest**. The launch script bind mounts real Binderfs nodes into the container, then checks Android boot and the SurfaceFlinger renderer before reporting success.

The repository includes [`compose.yaml`](compose.yaml) for Redroid and [`compose.apk.yaml`](compose.apk.yaml) for the optional APK bind mount. `emulator.sh start` copies these files and the selected profiles into `/opt/vemu/` in the guest, then runs `docker compose up -d --force-recreate` there. The Mac script manages QEMU; Compose manages the Android container.

The guest disk can originate from Colima, as it did in the tested setup, but starting a Colima profile does not start vemu's QEMU/VirGL configuration. Stop the Colima VM before copying or booting its disk in vemu; the two launchers must not write the same disk at once.

## Requirements

| Location | Requirement |
| --- | --- |
| Mac | Apple Silicon macOS; `clang`, `codesign`, Python 3, SSH, and [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) (`adb`). [scrcpy](https://github.com/Genymobile/scrcpy) is optional for a display window. |
| Runtime directory | `~/.local/share/vemu/UTM.app` from [UTM](https://docs.getutm.app/installation/macos/) 4.6.5, `disk.raw`, and an SSH private key named `ssh_key`. |
| Linux guest | ARM64 Linux with SSH, passwordless `sudo`, Docker Compose, loadable `binder_linux` and `ashmem_linux` modules, and a working `/dev/dri/renderD128`. The guest network must use MAC `52:55:55:1d:5c:cd`. |

The tested combination is Apple M3 Max, macOS 14.3, UTM 4.6.5 / QEMU 9.1.2, and `redroid/redroid:16.0.0_64only-latest`. UTM, the guest disk, SSH keys, APKs, and Android data volumes are not committed to Git. The launch script uses 4 vCPUs and 6 GiB guest RAM.

`VEMU_HOME` can point to a different runtime directory, and `VEMU_GUEST_USER` can select a Linux guest username other than the current Mac username. These are environment variables; they are not CLI options.

## Quick start with a prepared guest

1. Place `UTM.app`, `disk.raw`, and `ssh_key` in `~/.local/share/vemu/`. The key must log into the guest user, which needs passwordless `sudo`.
2. Clone this repository and start the default Pixel 10 Pro profile:

   ```bash
   git clone https://github.com/johnsonlee/vemu.git
   cd vemu
   ./.agents/skills/emulator/scripts/emulator.sh start
   ```

3. Connect to the Android display, if desired:

   ```bash
   scrcpy -s 127.0.0.1:5556
   ```

4. Stop the guest without deleting Android data:

   ```bash
   ./.agents/skills/emulator/scripts/emulator.sh stop
   ```

The launch script compiles and signs its small QEMU loader on first use, provisions Binderfs in the guest, syncs Compose and profile files, creates the selected data volume, and waits for Android and VirGL. SSH listens on Mac `127.0.0.1:2223`; ADB listens on Mac `127.0.0.1:5556`.

## CLI

```text
emulator.sh start [--profile PROFILE] [--name NAME] [--apk /path/to/app.apk]
emulator.sh stop [--name NAME]
```

| Option | Effect |
| --- | --- |
| `--profile` | Selects `default`, `pixel-10-pro`, or `s25-ultra`. `default` is a symlink to `pixel-10-pro`. |
| `--name` | Sets the Docker container name and Android `ro.product.device`, shown as `device:` by `adb devices -l`. Default: `vemu`. It does **not** change the ADB serial (`127.0.0.1:5556`) or the profile's model. |
| `--apk` | Installs an APK during `start`. The script copies it from the Mac to the Linux guest once per SHA-256 hash, bind mounts it read-only as `/data/local/tmp/app.apk`, and runs `pm install -r` inside the container. It does not copy the APK through ADB. |

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
adb -s 127.0.0.1:5556 shell wm size
adb -s 127.0.0.1:5556 shell wm density
adb -s 127.0.0.1:5556 shell dumpsys SurfaceFlinger | grep '^GLES:'
```

Expect `sys.boot_completed=1`, the selected model and screen settings, and a renderer containing `virgl` and `Apple`. On the tested M3 Max, SurfaceFlinger reported `virgl (ANGLE (Apple, Apple M3 Max, OpenGL 4.1 Metal - 88))`. This verifies the graphics path, not frame rate or performance.

## Known limitations

- There is no automated Colima setup, disk clone, or distributed guest image yet. The current script expects the specific ARM64 guest capabilities and network configuration above.
- The Redroid container runs with Docker `privileged` access and mapped Binder devices inside the dedicated guest.
- Profiles change visible model and display properties. The build fingerprint, WebView version, and underlying hardware remain Redroid. Apps may override their own User-Agent; these profiles do not provide genuine Samsung or Google firmware or device integrity attestation. See the [Android WebSettings API](https://developer.android.com/reference/android/webkit/WebSettings).
- GPU functionality has been checked on one Mac configuration. Other Apple Silicon Macs and guest kernels need verification.

## Contributing

Issues and pull requests are welcome. For runtime bugs, include the Mac model and macOS version, guest kernel and Docker Compose versions, selected profile, `adb devices -l`, and the SurfaceFlinger `GLES:` line. Remove private keys, APKs, account data, and other sensitive logs before attaching files. Run `shellcheck` on changed shell scripts and `docker compose config --quiet` for affected profiles; see the project [emulator skill](.agents/skills/emulator/SKILL.md) for runtime invariants.

## License

[MIT](LICENSE). UTM, Redroid, Android, and scrcpy are separate projects under their own licenses.
