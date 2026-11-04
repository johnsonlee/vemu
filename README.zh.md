# vemu

[English](README.md) · [MIT 许可证](LICENSE)

vemu 在 Apple Silicon Mac 上运行使用 GPU 渲染的 Android 16。它通过 UTM 的 QEMU 启动 ARM64 Linux 客机，在客机中通过 Docker Compose 运行 [Redroid](https://github.com/remote-android/redroid-doc)，再经 VirGL 和 ANGLE 将 Android 的 OpenGL 绘制交给 Mac GPU。设备配置可切换 Android 系统属性和屏幕参数。

> [!IMPORTANT]
> **实验性项目。** 本仓库尚不能构建或分发 Linux 客机磁盘。仅克隆仓库无法直接启动；需要先提供下文所述的预配置客机。GPU 渲染路径只在一台 M3 Max Mac 上验证过，尚无性能基准测试结论。

UTM 提供 QEMU，但不会自动提供此启动脚本所需的 Linux 系统。`emulator.sh` 会直接打开 `disk.raw`；该客机必须事先具备 Docker Compose、Binder/ashmem 支持和 virtio-gpu 渲染节点。自动构建客机的流程尚未实现。

## 工作原理

```text
Android 应用 → Redroid 容器 → Linux virtio-gpu/VirGL
             → UTM QEMU (HVF) → ANGLE/Metal → Mac GPU

Mac adb :5556 → QEMU 端口转发 → 客机 Docker :5555 → Android adbd
```

Mac 同时运行一个 QEMU 客机和一个活动的 Android 容器。Docker Compose **运行在 Linux 客机内**。启动脚本将真实的 Binderfs 设备节点映射进容器，然后检查 Android 是否开机以及 SurfaceFlinger 的渲染器，确认后才报告成功。

## 运行条件

| 位置 | 要求 |
| --- | --- |
| Mac | Apple Silicon macOS；`clang`、`codesign`、Python 3、SSH，以及包含 `adb` 的 [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools)。[scrcpy](https://github.com/Genymobile/scrcpy) 可选，用于显示 Android 画面。 |
| 运行目录 | `~/.local/share/vemu/UTM.app`，取自 [UTM](https://docs.getutm.app/installation/macos/) 4.6.5；另需 `disk.raw` 和名为 `ssh_key` 的 SSH 私钥。 |
| Linux 客机 | ARM64 Linux，具备 SSH、免密码 `sudo`、Docker Compose、可加载的 `binder_linux` 与 `ashmem_linux` 模块，以及可用的 `/dev/dri/renderD128`。客机网络配置必须使用 MAC 地址 `52:55:55:1d:5c:cd`。 |

已验证的组合为 Apple M3 Max、macOS 14.3、UTM 4.6.5 / QEMU 9.1.2，以及 `redroid/redroid:16.0.0_64only-latest`。UTM、客机磁盘、SSH 密钥、APK 和 Android 数据卷都不会提交到 Git。启动脚本为客机分配 4 个 vCPU 和 6 GiB 内存。

可以用环境变量 `VEMU_HOME` 指向其他运行目录，也可以用 `VEMU_GUEST_USER` 指定与当前 Mac 用户名不同的 Linux 客机用户名。这两个是环境变量，不是命令行选项。

## 使用已准备好的客机快速开始

1. 将 `UTM.app`、`disk.raw` 和 `ssh_key` 放在 `~/.local/share/vemu/`。私钥必须能登录客机用户，且该用户需要免密码 `sudo` 权限。
2. 克隆仓库并启动默认的 Pixel 10 Pro 配置：

   ```bash
   git clone https://github.com/johnsonlee/vemu.git
   cd vemu
   ./.agents/skills/emulator/scripts/emulator.sh start
   ```

3. 如需显示 Android 画面：

   ```bash
   scrcpy -s 127.0.0.1:5556
   ```

4. 停止客机，保留 Android 数据：

   ```bash
   ./.agents/skills/emulator/scripts/emulator.sh stop
   ```

首次使用时，启动脚本会编译并签名一个小型 QEMU 加载器，在客机中配置 Binderfs、同步 Compose 与设备配置文件、创建所选数据卷，并等待 Android 和 VirGL 就绪。Mac 上的 SSH 监听 `127.0.0.1:2223`，ADB 监听 `127.0.0.1:5556`。

## 命令行用法

```text
emulator.sh start [--profile PROFILE] [--name NAME] [--apk /path/to/app.apk]
emulator.sh stop [--name NAME]
```

| 选项 | 作用 |
| --- | --- |
| `--profile` | 选择 `default`、`pixel-10-pro` 或 `s25-ultra`。`default` 是指向 `pixel-10-pro` 的符号链接。 |
| `--name` | 设置 Docker 容器名和 Android 的 `ro.product.device`，后者显示为 `adb devices -l` 输出中的 `device:`。默认值为 `vemu`。它**不会**改变 ADB serial（`127.0.0.1:5556`）或配置中的设备型号。 |
| `--apk` | 在 `start` 期间安装 APK。脚本按 SHA-256 哈希将 APK 从 Mac 向 Linux 客机复制一次，然后以只读方式映射为容器内的 `/data/local/tmp/app.apk`，在容器内运行 `pm install -r`。APK 不通过 ADB 复制。 |

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
adb -s 127.0.0.1:5556 shell wm size
adb -s 127.0.0.1:5556 shell wm density
adb -s 127.0.0.1:5556 shell dumpsys SurfaceFlinger | grep '^GLES:'
```

预期结果是 `sys.boot_completed=1`、所选型号和屏幕参数，以及包含 `virgl` 和 `Apple` 的渲染器。在测试使用的 M3 Max 上，SurfaceFlinger 报告 `virgl (ANGLE (Apple, Apple M3 Max, OpenGL 4.1 Metal - 88))`。这验证的是图形渲染路径，不代表帧率或性能结论。

## 已知限制

- 目前没有客机磁盘的自动准备流程，也未提供客机镜像。当前脚本要求客机具备上述 ARM64 能力和网络配置。
- Redroid 容器在专用客机内以 Docker `privileged` 权限运行，并映射 Binder 设备。
- 配置只改变可见的型号和屏幕属性。构建指纹、WebView 版本和底层硬件仍属于 Redroid。应用可以覆盖自己的 User-Agent；这些配置不会提供真正的 Samsung 或 Google 固件，也不能提供设备完整性证明。参见 [Android WebSettings API](https://developer.android.com/reference/android/webkit/WebSettings)。
- GPU 功能目前只在一种 Mac 配置上验证过。其他 Apple Silicon Mac 和客机内核仍需验证。

## 参与贡献

欢迎提交 Issue 和 Pull Request。报告运行问题时，请附上 Mac 型号和 macOS 版本、客机内核与 Docker Compose 版本、所选配置、`adb devices -l` 输出，以及 SurfaceFlinger 的 `GLES:` 行。附加文件前，请移除私钥、APK、账号数据和其他敏感日志。修改 Shell 脚本后运行 `shellcheck`，修改配置后对受影响的 profile 运行 `docker compose config --quiet`；运行时约束见项目的 [emulator Skill](.agents/skills/emulator/SKILL.md)。

## 许可证

本项目采用 [MIT 许可证](LICENSE)。UTM、Redroid、Android 和 scrcpy 是独立项目，分别遵循各自的许可证。
