# Historical ARM HVF idle CPU investigation

This page preserves measurements from the former UTM 4.6.5 / QEMU 9.1.2 runtime. In that build, ARM `hvf_wfi()` returned to `hv_vcpu_run()` without sleeping when the next guest virtual timer interrupt was less than 2 ms away. Frequent short timers could therefore consume host CPU while Linux reported its vCPUs as mostly idle. The relevant [QEMU 9.1.2 source](https://github.com/qemu/qemu/blob/v9.1.2/target/arm/hvf/hvf.c) documents the 2 ms shortcut as a latency tradeoff.

The current source-build path requires QEMU 11.1.3 or newer. Its [ARM HVF WFI implementation](https://github.com/qemu/qemu/blob/v11.1.3/target/arm/hvf/hvf.c) arms a QEMU virtual timer and halts the vCPU until the timer or another event wakes it. vemu no longer byte-patches QEMU or injects a private-symbol interposer. The measurements below do not establish the new runtime's CPU performance; that requires representative multi-graph load testing.

On the tested M3 Max/macOS 14.3 host, a controlled four-vCPU load of one 1 ms sleeper per vCPU produced these 12-second measurements with the Android container paused:

| QEMU wait path | Host QEMU CPU during load | Completed sleeps per guest thread |
| --- | ---: | ---: |
| Original 2 ms spin shortcut | 319% | ~10,930 |
| Remove shortcut, use plain `pselect` | 11% | ~2,000 |
| Remove shortcut, use critical `kqueue` timer + IPI-safe `pselect` | 37% | ~9,960 |

One hundred percent host CPU means one logical core. These are timer-stress results, not general Android benchmarks. Coupang in the foreground at 30 FPS remained around 7–9% QEMU CPU for 80 seconds after startup with the patched wait path; the original high idle usage was intermittent, so this alone cannot prove long-term elimination of every high-CPU episode.

## Former implementation

The former `scripts/prepare-idle-qemu.sh` extracted the ARM64 slice of the pinned UTM QEMU framework, verified its exact SHA-256, replaced one branch instruction in a runtime copy, and signed it. A small interposer created a one-shot `EVFILT_TIMER` with `NOTE_NSECONDS | NOTE_CRITICAL`; its kqueue fd became readable at the guest timer deadline. QEMU still called `pselect` with its IPI signal mask, so an IPI could interrupt the wait atomically. The interposer canceled the timer after each wait. On the tested Mac, 1,000 standalone 1 ms waits averaged 1.03 ms with this path versus 1.50 ms with plain `pselect`.

The interposer called macOS's private `__pselect` symbol to avoid recursive dyld interposition. The QEMU byte patch was specific to UTM 4.6.5's ARM64 build. Both have been removed from vemu's runtime.
