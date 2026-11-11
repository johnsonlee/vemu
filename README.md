# vemu

[简体中文](README.zh.md) · [MIT License](LICENSE)

vemu runs Android 16 on Apple Silicon macOS with GPU-backed rendering. It starts an ARM64 Linux guest with a locally built QEMU, runs [Redroid](https://github.com/remote-android/redroid-doc) through Docker Compose, and sends Android OpenGL work through VirGL and ANGLE to the Mac GPU. Device profiles select Android properties and display settings.

> [!IMPORTANT]
> **Experimental setup.** First start builds GPU-enabled QEMU and its graphics dependencies from source in the user's runtime directory, then creates a dedicated Linux guest disk. The new path booted Redroid with VirGL on one M3 Max Mac; other Macs still need testing. `vemu start` fails if Android's renderer does not name VirGL and Apple.

On first start, vemu creates a dedicated [Colima](https://github.com/abiosoft/colima)/Lima ARM64 Ubuntu guest with QEMU, prepares Docker, Binder/ashmem, and SSH, stops Colima, and copies its root disk, QCOW2 data disk, and cloud-init ISO. `vemu` then boots those copies directly with the locally built QEMU to expose the VirGL render device. Colima prepares the disks; it does not run alongside vemu.

## How it works

```text
Android app → Redroid container → Linux virtio-gpu/VirGL
            → local QEMU (HVF) → ANGLE/Metal → Mac GPU

Mac adb :5556 → QEMU port forward → guest Docker :5555 → Android adbd
```

The Mac runs one QEMU guest and one active Android container at a time. Docker Compose runs **inside the Linux guest**. The launch script bind mounts real Binderfs nodes into the container, then checks Android boot and the SurfaceFlinger renderer before reporting success.

The repository includes [`compose.yaml`](compose.yaml) for Redroid and [`compose.apk.yaml`](compose.apk.yaml) for the optional APK bind mount. `vemu start` copies these files and the selected profiles into `/opt/vemu/` in the guest, then runs `docker compose up -d --force-recreate` there. The Mac script manages QEMU; Compose manages the Android container.

The setup script stops the `vemu-qemu-seed` Colima profile before copying its disk. It retains the stopped seed profile for troubleshooting. vemu uses a separate disk copy, so Colima never writes to vemu's active disk.

## Requirements

| Location | Requirement |
| --- | --- |
| Mac | Apple Silicon macOS, [Homebrew](https://brew.sh/), Xcode Command Line Tools (`clang`), Python 3, and SSH. [scrcpy](https://github.com/Genymobile/scrcpy) is optional for a display window. |
| First start | Network access and free disk space for a 30 GiB guest root disk, a 30 GiB QCOW2 data disk, their copies, QEMU and graphics build dependencies, Linux packages, and the Redroid image. The script installs missing Colima, Docker CLI, and [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) with Homebrew. |
| Runtime directory | `~/.local/share/vemu/` holds the source-build toolchain, signed QEMU runtime, `disk.raw`, `datadisk.qcow2`, `cidata.iso`, a dedicated SSH key, and the guest NIC MAC. These are created automatically without administrator privileges. |

The source-built path was verified on Apple M3 Max, macOS 14.3, QEMU 11.1.3, and `redroid/redroid:16.0.0_64only-latest`. QEMU, guest disks, SSH keys, APKs, and Android data volumes are not committed to Git. The launch script uses 4 vCPUs and 6 GiB guest RAM.

`VEMU_HOME` can point to a different runtime directory. `VEMU_GUEST_USER` can select another username for a manually prepared guest; automated setup uses the current Mac username. These are environment variables, not CLI options.

## Quick start

1. Install [Homebrew](https://brew.sh/) and Xcode Command Line Tools (`xcode-select --install`) if needed. Clone the repository and start the default Pixel 10 Pro profile:

   ```bash
   git clone https://github.com/johnsonlee/vemu.git
   cd vemu
   ./.agents/skills/emulator/scripts/vemu start
   ```

   The first start bootstraps a private, rootless [MacPorts](https://www.macports.org/) build tree in `VEMU_HOME`, compiles QEMU with VirGL and SPICE, creates a bootable Colima QEMU seed, copies its stopped disks, pulls Redroid, and starts Android. On older Apple Clang versions, it installs Homebrew LLVM to compile GN and QEMU. No system MacPorts installation or `sudo` on the Mac is required. Building the graphics stack from source can take hours; later starts reuse it and the disks.

2. Connect to the Android display, if desired:

   ```bash
   ./.agents/skills/emulator/scripts/vemu scrcpy
   ```

3. Stop the guest without deleting Android data:

   ```bash
   ./.agents/skills/emulator/scripts/vemu stop
   ```

Run `vemu setup` to prepare the runtime without starting Android. It builds and signs QEMU with the Hypervisor entitlement, provisions Binderfs in a Colima QEMU seed guest, and copies its stopped root and data disks and cloud-init ISO. `vemu start` then syncs Compose and profile files, creates the selected data volume, and waits for Android and VirGL. SSH listens on Mac `127.0.0.1:2223`; ADB listens on Mac `127.0.0.1:5556`.

## CLI

```text
vemu start [--profile PROFILE] [--name NAME] [--apk /path/to/app.apk] [--fps 1-120]
vemu stop [--name NAME]
vemu setup
vemu scrcpy [--secure]
```

| Option | Effect |
| --- | --- |
| `--profile` | Selects `default`, `pixel-10-pro`, or `s25-ultra`. `default` is a symlink to `pixel-10-pro`. |
| `--name` | Sets the Docker container name and Android `ro.product.device`, shown as `device:` by `adb devices -l`. Default: `vemu`. It does **not** change the ADB serial (`127.0.0.1:5556`) or the profile's model. |
| `--apk` | Installs an APK during `start`. The script copies it from the Mac to the Linux guest once per SHA-256 hash, bind mounts it read-only as `/data/local/tmp/app.apk`, and runs `pm install -r` inside the container. It does not copy the APK through ADB. |
| `--fps` | Sets Redroid's display refresh cap. Default: 30. Use `--fps 15` if you prefer a lower refresh rate. |

The old QEMU 9.1.2 runtime needed a binary patch and a macOS symbol interposer to avoid spinning on short WFI timers. QEMU 11.1.3 uses an event-driven WFI timer, so vemu no longer applies that binary patch or loads the interposer. It does apply small, tracked source patches to enable ANGLE Metal EGL in QEMU and VirGL. See the [historical idle CPU analysis](docs/idle-cpu.md). The new runtime's CPU behavior still needs representative multi-graph load testing.


Examples:

```bash
./.agents/skills/emulator/scripts/vemu start --profile s25-ultra --name s25-test
./.agents/skills/emulator/scripts/vemu start --apk /absolute/path/app.apk
adb devices -l
```

The first APK transfer from the Mac into the guest is still necessary because this QEMU setup has no shared filesystem. Reusing the same APK skips that transfer.

## Runtime security

vemu no longer downloads or executes UTM or byte-patches its QEMU framework. The QEMU build uses checked source archives from a private MacPorts tree plus the tracked [QEMU EGL](.agents/skills/emulator/assets/qemu-macos-egl.patch) and [VirGL EGL](.agents/skills/emulator/assets/virglrenderer-macos-egl.patch) patches, rejects QEMU older than 11.1.3, and disables the VNC server. Its SSH and ADB forwards bind to Mac loopback. The runtime directory is accessible only to the current Mac user, protecting its SSH key and local SPICE socket. The build and VM run under that user; no Mac administrator privilege is required.

VirGL and SPICE still parse data from the guest on the host. Removing UTM does not make GPU virtualization a security boundary against hostile Android or Linux code. The original security rejection did not include a CVE or policy finding, so this change cannot claim that every reviewer criterion is satisfied. Review the selected QEMU, virglrenderer, ANGLE, and SPICE versions before using untrusted workloads.

## Secure activities

Android's `FLAG_SECURE` normally makes protected activities black in scrcpy. Run `vemu scrcpy --secure` to use a patched scrcpy 4.1 server as Android's `system` user and create a secure virtual display. A test activity with `FLAG_SECURE` was black in stock scrcpy and visible through this command. It mirrors protected content to the Mac, so use it only with apps and data you intend to display. This is separate from DRM protected video. The bundled server's source, patch, build instructions, and Apache 2.0 license are in [assets](.agents/skills/emulator/assets/scrcpy-secure-README.md).

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

Expect `sys.boot_completed=1`, the selected model and screen settings, and a renderer containing `virgl` and `Apple`. On the tested M3 Max, the source-built runtime's renderer contained `virgl (ANGLE (Apple, ANGLE Metal Renderer: Apple M3 Max`. Renderer identity verifies the graphics path, not frame rate or performance.

## Known limitations

- The setup path has been tested on one M3 Max Mac. It relies on Colima's current ARM64 Ubuntu kernel and a pinned ashmem DKMS source; a different guest kernel may need updated module support. No guest image is distributed.
- The Redroid container runs with Docker `privileged` access and mapped Binder devices inside the dedicated guest.
- Profiles change reported identity strings, including the fingerprint and Java `http.agent`, plus display properties. The actual firmware, security patch contents, WebView version, and hardware remain Redroid. `--name` still overrides `ro.product.device` for ADB's `device:` field, even though the reported fingerprint contains the profile's device codename. Apps may override their own User-Agent; these profiles cannot provide genuine Samsung or Google firmware or device integrity attestation. See the [Android WebSettings API](https://developer.android.com/reference/android/webkit/WebSettings).
- The source-built GPU path has been verified on one Apple M3 Max / macOS 14.3 machine. Other Macs and guest kernels still need verification.

## Contributing

Issues and pull requests are welcome. For runtime bugs, include the Mac model and macOS version, guest kernel and Docker Compose versions, selected profile, `adb devices -l`, and the SurfaceFlinger `GLES:` line. Remove private keys, APKs, account data, and other sensitive logs before attaching files. Run `shellcheck` on changed shell scripts and `docker compose config --quiet` for affected profiles; see the project [emulator skill](.agents/skills/emulator/SKILL.md) for runtime invariants.

## License

[MIT](LICENSE). QEMU, MacPorts, Redroid, Android, and scrcpy are separate projects under their own licenses.
