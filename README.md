# vemu

在 Apple Silicon Mac 上运行 GPU 加速的 Android 16。vemu 用 UTM 的 QEMU 启动 ARM64 Linux 客机，借助 `virtio-gpu-gl-pci` / VirGL 把 Redroid 的 OpenGL 绘制交给 macOS 的 ANGLE/Metal。Android 容器由 Docker Compose 管理，机型配置通过只读 `build.prop` 文件映射切换。

已在 Apple M3 Max、macOS 14.3、UTM 4.6.5 / QEMU 9.1.2 上验证：Android 16 正常开机，SurfaceFlinger 报告 `virgl (ANGLE (Apple, Apple M3 Max, OpenGL 4.1 Metal - 88))`，Android 应用使用 Skia OpenGL 绘制。这是功能验证，未做性能基准测试。

## 运行前提

- Apple Silicon Mac，已安装 `clang`、`codesign`、`ssh`、`adb`；查看 Android 窗口可用 `scrcpy`。
- `~/.local/share/vemu/UTM.app`：官方 UTM 4.6.5 应用，含 QEMU dylib 和 ARM64 UEFI 固件。
- `~/.local/share/vemu/disk.raw`：预先配置好的 ARM64 Linux 磁盘，包含 Docker Compose、Binder/ashmem 内核模块及能访问 `/dev/dri/renderD128` 的 virtio-gpu 驱动。
- `~/.local/share/vemu/ssh_key`：可登录该客机的私钥。客机用户名默认与 Mac 当前用户名相同，且应具有免交互 `sudo` 权限。

运行资产不会提交到 Git。本仓库暂未自动创建 Linux 磁盘；脚本针对已准备好的专用客机，网卡 MAC 固定为 `52:55:55:1d:5c:cd`，客机网络配置需与之匹配。已有资产放在别处时，可设 `VEMU_HOME`；客机用户名不同时，可设 `VEMU_GUEST_USER`。

## 启动与停止

```bash
./.agents/skills/emulator/scripts/emulator.sh start
scrcpy -s 127.0.0.1:5556
./.agents/skills/emulator/scripts/emulator.sh stop
```

默认 profile 为 `default`，它是 `pixel-10-pro` 的符号链接。要切换机型或为当前容器命名：

```bash
./.agents/skills/emulator/scripts/emulator.sh start --profile s25-ultra --name test-s25
adb devices -l   # device:test-s25；model:SM-S938B
./.agents/skills/emulator/scripts/emulator.sh stop
```

`--name` 同时设置 Docker 容器名和 `adb devices -l` 的 `device:` 字段；`model:` 仍取自机型 profile。ADB 的 serial 由端口转发决定，仍是 `127.0.0.1:5556`。单个 QEMU 客机同一时间运行一个 Android 容器。Mac 上 SSH 只监听 `127.0.0.1:2223`，ADB 只监听 `127.0.0.1:5556`。停止时保留 Android 数据卷。

启动时安装 APK：

```bash
./.agents/skills/emulator/scripts/emulator.sh start --profile default --apk /absolute/path/app.apk
```

脚本按 SHA-256 将 Mac 上的 APK 传到 Linux 客机的 `/opt/vemu/apks/`，相同内容再次启动会直接使用缓存。`compose.apk.yaml` 把该文件只读映射到容器内的 `/data/local/tmp/app.apk`，然后在容器内运行 `pm install -r`。这里没有 ADB 文件传输；Mac 与 Linux 客机之间首次传输仍是必要的，因为当前 QEMU 配置没有共享文件系统。

## 机型配置

| Profile | Android 型号 | 屏幕像素 | 逻辑 DPI | 数据卷 |
| --- | --- | ---: | ---: | --- |
| `default` → `pixel-10-pro` | Pixel 10 Pro | 1280×2856 | 480 | `vemu-pixel-10-pro-data` |
| `s25-ultra` | Galaxy S25 Ultra (`SM-S938B`) | 1440×3120 | 480* | `vemu-s25-ultra-data` |

屏幕像素来自 [Google](https://store.google.com/product/pixel_10_pro_specs?hl=en-US) 与 [Samsung](https://www.samsung.com/co/business/smartphones/galaxy-s/galaxy-s25-ultra-titanium-silverblue-1tb-sm-s938bzbultc/) 的原生分辨率规格。*S25 Ultra 的 480 是本配置的布局密度选择，并非厂商公布的物理 PPI 或真机默认逻辑 DPI。Pixel 10 Pro 的 480 参考 Android 虚拟设备基线。

每套配置在 `profiles/<name>/profile.env` 中声明屏幕参数和数据卷。`compose.yaml` 将六个分区的完整属性文件只读映射到容器：system、vendor、product、odm、system_ext、vendor_dlkm。顶层 `ro.product.*` 值由这些分区合成，只改 system/vendor 两个文件会留下不一致的型号。基线文件取自 Redroid 16 镜像。修改 profile 定义后重新生成文件并启动：

```bash
python3 .agents/skills/emulator/scripts/generate-profiles.py
./.agents/skills/emulator/scripts/emulator.sh start --profile default
```

机型信息会影响 Android `Build.MODEL` 和默认 WebView UA 的型号字段。镜像自身的构建号、WebView 版本、构建指纹及硬件实现仍是 Redroid；应用也可以单独覆盖 UA。这套配置不会变成 Samsung/Google 固件，也不保证与真机 UA 完全一致或通过设备完整性检查。[Android WebSettings API](https://developer.android.com/reference/android/webkit/WebSettings) 说明了默认 UA 与应用级覆盖。

## 验证

```bash
adb -s 127.0.0.1:5556 shell getprop sys.boot_completed
adb -s 127.0.0.1:5556 shell getprop ro.product.model
adb -s 127.0.0.1:5556 shell getprop ro.product.device
adb -s 127.0.0.1:5556 shell wm size
adb -s 127.0.0.1:5556 shell wm density
adb -s 127.0.0.1:5556 shell dumpsys SurfaceFlinger | grep '^GLES:'
```

应看到 `sys.boot_completed=1`、所选型号、`--name` 指定的 device 值和屏幕参数，以及包含 `virgl` 与 `Apple` 的 GLES 渲染器。项目维护流程见 [emulator Skill](.agents/skills/emulator/SKILL.md)。
