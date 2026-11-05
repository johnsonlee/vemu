# vemu

[English](README.md) · [MIT 许可证](LICENSE)

vemu 在 Apple Silicon Mac 上运行使用 GPU 渲染的 Android 16。它通过 UTM 的 QEMU 启动 ARM64 Linux 客机，在客机中通过 Docker Compose 运行 [Redroid](https://github.com/remote-android/redroid-doc)，再经 VirGL 和 ANGLE 将 Android 的 OpenGL 绘制交给 Mac GPU。设备配置可切换 Android 系统属性和屏幕参数。

> [!IMPORTANT]
> **实验性项目。** 首次启动会自动下载 UTM 并创建专用的 Linux 客机磁盘。完整的全新安装流程只在一台 M3 Max Mac 上验证过；其他 Apple Silicon Mac 和未来的客机内核仍需测试。尚无性能基准测试结论。

首次启动时，vemu 会创建专用的 [Colima](https://github.com/abiosoft/colima)/Lima ARM64 Ubuntu 客机，准备 Docker、Binder/ashmem 和 SSH，停止 Colima 后复制其根磁盘。随后 `emulator.sh` 使用 UTM 的 QEMU 直接启动磁盘副本，提供 VirGL 渲染设备。Colima 负责准备磁盘，不与 vemu 同时运行。

## 工作原理

```text
Android 应用 → Redroid 容器 → Linux virtio-gpu/VirGL
             → UTM QEMU (HVF) → ANGLE/Metal → Mac GPU

Mac adb :5556 → QEMU 端口转发 → 客机 Docker :5555 → Android adbd
```

Mac 同时运行一个 QEMU 客机和一个活动的 Android 容器。Docker Compose **运行在 Linux 客机内**。启动脚本将真实的 Binderfs 设备节点映射进容器，然后检查 Android 是否开机以及 SurfaceFlinger 的渲染器，确认后才报告成功。

仓库包含用于 Redroid 的 [`compose.yaml`](compose.yaml)，以及安装 APK 时额外使用的 [`compose.apk.yaml`](compose.apk.yaml)。`emulator.sh start` 将这些文件和机型配置复制到客机的 `/opt/vemu/`，然后在客机中运行 `docker compose up -d --force-recreate`。Mac 脚本管理 QEMU，Compose 管理 Android 容器。

准备脚本会先停止 `vemu-seed` Colima profile，再复制磁盘。已停止的种子 profile 会保留，便于排查问题；vemu 使用独立副本，Colima 不会写入 vemu 正在使用的磁盘。

## 运行条件

| 位置 | 要求 |
| --- | --- |
| Mac | Apple Silicon macOS、[Homebrew](https://brew.sh/)、Xcode Command Line Tools（`clang`）、Python 3 和 SSH。[scrcpy](https://github.com/Genymobile/scrcpy) 可选，用于显示 Android 画面。 |
| 首次启动 | 需要网络连接，以及足够容纳 30 GiB 客机根磁盘及其副本、UTM、Linux 软件包和 Redroid 镜像的磁盘空间。脚本会通过 Homebrew 安装缺少的 Colima、Docker CLI 和 [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools)。 |
| 运行目录 | `~/.local/share/vemu/` 保存自动下载或链接的 UTM 4.6.5、`disk.raw`、专用 SSH 密钥和客机网卡 MAC 地址。 |

已验证的组合为 Apple M3 Max、macOS 14.3、UTM 4.6.5 / QEMU 9.1.2，以及 `redroid/redroid:16.0.0_64only-latest`。UTM、客机磁盘、SSH 密钥、APK 和 Android 数据卷都不会提交到 Git。启动脚本为客机分配 4 个 vCPU 和 6 GiB 内存。

可以用 `VEMU_HOME` 指向其他运行目录。对于手工准备的客机，可以用 `VEMU_GUEST_USER` 指定其他 Linux 用户名；自动准备流程使用当前 Mac 用户名。这两个是环境变量，不是命令行选项。

## 快速开始

1. 如尚未安装，先安装 [Homebrew](https://brew.sh/) 和 Xcode Command Line Tools（`xcode-select --install`）。克隆仓库并启动默认的 Pixel 10 Pro 配置：

   ```bash
   git clone https://github.com/johnsonlee/vemu.git
   cd vemu
   ./.agents/skills/emulator/scripts/emulator.sh start
   ```

   首次启动会从 [UTM 4.6.5 官方 GitHub 发布页](https://github.com/utmapp/UTM/releases/tag/v4.6.5)下载 UTM（如果 `/Applications` 中已有该版本则直接使用），创建并配置 Colima 种子客机，复制已停止客机的根磁盘，拉取 Redroid 镜像并启动 Android。这一步可能需要几分钟；以后启动会复用磁盘。

2. 如需显示 Android 画面：

   ```bash
   ./.agents/skills/emulator/scripts/emulator.sh view
   ```

3. 停止客机，保留 Android 数据：

   ```bash
   ./.agents/skills/emulator/scripts/emulator.sh stop
   ```

可以先运行 `emulator.sh setup`，只准备运行环境而不启动 Android。启动命令会在首次使用时编译并签名一个小型 QEMU 加载器，在客机中配置 Binderfs、同步 Compose 与设备配置文件、创建所选数据卷，并等待 Android 和 VirGL 就绪。Mac 上的 SSH 监听 `127.0.0.1:2223`，ADB 监听 `127.0.0.1:5556`。

## 命令行用法

```text
emulator.sh start [--profile PROFILE] [--name NAME] [--apk /path/to/app.apk] [--fps 1-120]
emulator.sh stop [--name NAME]
emulator.sh setup
emulator.sh view [--secure]
```

| 选项 | 作用 |
| --- | --- |
| `--profile` | 选择 `default`、`pixel-10-pro` 或 `s25-ultra`。`default` 是指向 `pixel-10-pro` 的符号链接。 |
| `--name` | 设置 Docker 容器名和 Android 的 `ro.product.device`，后者显示为 `adb devices -l` 输出中的 `device:`。默认值为 `vemu`。它**不会**改变 ADB serial（`127.0.0.1:5556`）或配置中的设备型号。 |
| `--apk` | 在 `start` 期间安装 APK。脚本按 SHA-256 哈希将 APK 从 Mac 向 Linux 客机复制一次，然后以只读方式映射为容器内的 `/data/local/tmp/app.apk`，在容器内运行 `pm install -r`。APK 不通过 ADB 复制。 |
| `--fps` | 设置 Redroid 的画面刷新率上限。默认 15；需要更流畅的交互时可用 `--fps 30`，但空闲 CPU 占用可能更高。 |
| `view --secure` | 使用以 Android `system` 身份运行的定制 scrcpy 4.1 服务端，显示带 `FLAG_SECURE` 的 Activity。Mac 端需要 scrcpy 4.1。 |

在本地 M3 Max 的一次高频唤醒期间，15 FPS 将 QEMU 的 Mac CPU 占用从约 100% 降至约 10%。高占用是间歇性的，30 FPS 有时也很安静；帧率上限只是缓解措施，并非根本修复，而且会限制动画流畅度。

Android 的 `FLAG_SECURE` 会让普通 scrcpy 中的受保护页面变黑。可选的 `view --secure` 命令利用这套已取得 root 权限的 Redroid 镜像创建安全虚拟显示；实测同一测试 Activity 在普通 scrcpy 中是黑屏，在该命令下可见。该命令会把受保护内容显示到 Mac 上，请只用于你有意显示的应用和数据。它不保证能显示 DRM 保护的视频。服务端源码、补丁、构建方法和 Apache 2.0 许可证见 [assets](.agents/skills/emulator/assets/scrcpy-secure-README.md)。

示例：

```bash
./.agents/skills/emulator/scripts/emulator.sh start --profile s25-ultra --name s25-test
./.agents/skills/emulator/scripts/emulator.sh start --apk /absolute/path/app.apk
adb devices -l
```

由于当前 QEMU 配置没有共享文件系统，APK 首次从 Mac 传入客机仍是必要的；重复使用同一个 APK 时会跳过该次传输。

## 设备配置

| Profile | 报告的型号 | 屏幕像素 | 逻辑 DPI | Docker 数据卷 |
| --- | --- | ---: | ---: | --- |
| `default` → `pixel-10-pro` | Pixel 10 Pro | 1280 × 2856 | 480 | `vemu-pixel-10-pro-data` |
| `s25-ultra` | Galaxy S25 Ultra (`SM-S938B`) | 1440 × 3120 | 480* | `vemu-s25-ultra-data` |

屏幕像素数来自 [Google](https://store.google.com/product/pixel_10_pro_specs?hl=en-US) 和 [Samsung](https://www.samsung.com/co/business/smartphones/galaxy-s/galaxy-s25-ultra-titanium-silverblue-1tb-sm-s938bzbultc/)。*S25 Ultra 的逻辑 DPI 是本配置的选择，并非经验证的出厂默认值或屏幕物理 PPI。Pixel 10 Pro 的数值参考 Android 虚拟设备基线，并非零售真机的实测值。

每套配置包含一个 `profile.env` 文件，以及 system、vendor、product、odm、system_ext、vendor_dlkm 六个分区完整且以只读方式映射的 `build.prop` 文件。Android 根据这些分区合成顶层 `ro.product.*` 属性。各配置的数据卷相互独立；`default` 与 `pixel-10-pro` 指向同一配置，因此共用一个数据卷。

生成的属性文件也会为各配置设置指纹和对应的构建 ID。Pixel 10 Pro 的值来自 [Pixel 10 Pro 实机报告](https://github.com/google/filament/issues/9918)，Galaxy S25 Ultra 的值来自 [SM-S938B 实机诊断](https://github.com/appsfolder/livebridge/issues/42)。Android 会在 Java 进程启动时根据系统版本、型号和构建 ID 生成 `http.agent`；它与 WebView 或浏览器 User-Agent 不同（见 [AOSP RuntimeInit](https://android.googlesource.com/platform/frameworks/base/+/b9c98916b11932e7e55849c9c69d116002671a0e/core/java/com/android/internal/os/RuntimeInit.java)）。在已测试镜像中，默认配置返回 `Dalvik/2.1.0 (Linux; U; Android 16; Pixel 10 Pro Build/BD3A.251105.010.E1)`。

修改或新增配置时，更新 [`generate-profiles.py`](.agents/skills/emulator/scripts/generate-profiles.py) 中的 `PROFILES`，提供相应的 `profile.env`，重新生成属性文件并检查差异：

```bash
python3 .agents/skills/emulator/scripts/generate-profiles.py
```

仓库中的基础属性文件取自测试使用的 Redroid 16 镜像。镜像标签以 `latest` 结尾，可能发生变化；升级镜像前，应检查并更新基础属性文件和生成的各套配置。

## 验证运行中的实例

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

预期结果是 `sys.boot_completed=1`、所选型号和屏幕参数，以及包含 `virgl` 和 `Apple` 的渲染器。在测试使用的 M3 Max 上，SurfaceFlinger 报告 `virgl (ANGLE (Apple, Apple M3 Max, OpenGL 4.1 Metal - 88))`。这验证的是图形渲染路径，不代表帧率或性能结论。

## 已知限制

- 自动准备流程只在一台 M3 Max Mac 上验证过。它依赖 Colima 当前使用的 ARM64 Ubuntu 内核和固定版本的 ashmem DKMS 源码；未来内核可能需要更新模块支持。项目不分发客机镜像。
- Redroid 容器在专用客机内以 Docker `privileged` 权限运行，并映射 Binder 设备。
- 配置会改变上报的型号、指纹、Java `http.agent` 和屏幕参数；实际固件、安全补丁内容、WebView 版本及硬件仍属于 Redroid。`--name` 仍覆盖 `ro.product.device`，以设置 ADB 输出中的 `device:` 字段，因此该值会与指纹中的设备代号不同。应用可以覆盖自己的 User-Agent；这些配置不会提供真正的 Samsung 或 Google 固件，也不能提供设备完整性证明。参见 [Android WebSettings API](https://developer.android.com/reference/android/webkit/WebSettings)。
- GPU 功能目前只在一种 Mac 配置上验证过。其他 Apple Silicon Mac 和客机内核仍需验证。

## 参与贡献

欢迎提交 Issue 和 Pull Request。报告运行问题时，请附上 Mac 型号和 macOS 版本、客机内核与 Docker Compose 版本、所选配置、`adb devices -l` 输出，以及 SurfaceFlinger 的 `GLES:` 行。附加文件前，请移除私钥、APK、账号数据和其他敏感日志。修改 Shell 脚本后运行 `shellcheck`，修改配置后对受影响的 profile 运行 `docker compose config --quiet`；运行时约束见项目的 [emulator Skill](.agents/skills/emulator/SKILL.md)。

## 许可证

本项目采用 [MIT 许可证](LICENSE)。UTM、Redroid、Android 和 scrcpy 是独立项目，分别遵循各自的许可证。
