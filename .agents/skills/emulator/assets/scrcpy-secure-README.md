# Secure scrcpy server

`scrcpy-secure-server-4.1.apk` is a modified scrcpy 4.1 server for this rooted Redroid Android 16 image. It creates a virtual display with `VIRTUAL_DISPLAY_FLAG_SECURE | VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR` and runs as Android UID 1000 (`system`) via `scripts/secure-adb.sh`. This lets the virtual display show `FLAG_SECURE` activities. Stock scrcpy uses a nonsecure display and shows those activities as black.

Upstream: [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy), commit `2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0` (v4.1). Changes: `scrcpy-secure-4.1.patch`. License: `scrcpy-LICENSE` (Apache 2.0). The built server's SHA-256 is `bf8d47d46083a4a7f33a1e0ea494a40bf87da9adc3477368bdc8ed731e895511`.

To rebuild on a Mac with Java 17 and Android SDK Platform 36:

```bash
git clone https://github.com/Genymobile/scrcpy.git
cd scrcpy
git checkout 2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0
git apply --unidiff-zero /absolute/path/to/vemu/.agents/skills/emulator/assets/scrcpy-secure-4.1.patch
ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew :server:assembleRelease
cp server/build/outputs/apk/release/server-release-unsigned.apk /absolute/path/to/vemu/.agents/skills/emulator/assets/scrcpy-secure-server-4.1.apk
```

The server is invoked only by `emulator.sh view --secure`. It does not change the Android image or the installed app. The secure display intentionally mirrors content that an app would normally exclude from screen capture.
