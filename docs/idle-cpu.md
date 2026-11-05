# ARM HVF idle CPU

vemu uses UTM 4.6.5's QEMU 9.1.2 with Apple Hypervisor.framework. In that build, ARM `hvf_wfi()` returns to `hv_vcpu_run()` without sleeping when the next guest virtual timer interrupt is less than 2 ms away. Frequent short timers can therefore consume host CPU while Linux reports its vCPUs as mostly idle. The relevant [QEMU source](https://github.com/qemu/qemu/blob/v9.1.2/target/arm/hvf/hvf.c) documents the 2 ms shortcut as a latency tradeoff.

On the tested M3 Max/macOS 14.3 host, a controlled four-vCPU load of one 1 ms sleeper per vCPU produced these 12-second measurements with the Android container paused:

| QEMU wait path | Host QEMU CPU during load | Completed sleeps per guest thread |
| --- | ---: | ---: |
| Original 2 ms spin shortcut | 319% | ~10,930 |
| Remove shortcut, use plain `pselect` | 11% | ~2,000 |
| Remove shortcut, use critical `kqueue` timer + IPI-safe `pselect` | 37% | ~9,960 |

One hundred percent host CPU means one logical core. These are timer-stress results, not general Android benchmarks. Coupang in the foreground at 30 FPS remained around 7–9% QEMU CPU for 80 seconds after startup with the patched wait path; the original high idle usage was intermittent, so this alone cannot prove long-term elimination of every high-CPU episode.

## Implementation

`scripts/prepare-idle-qemu.sh` extracts the ARM64 slice of the pinned UTM QEMU framework, verifies its exact SHA-256, replaces one branch instruction in a runtime copy, and signs it. The original UTM binary remains intact. A small interposer creates a one-shot `EVFILT_TIMER` with `NOTE_NSECONDS | NOTE_CRITICAL`; its kqueue fd becomes readable at the guest timer deadline. QEMU still calls `pselect` with its IPI signal mask, so an IPI can interrupt the wait atomically. The interposer cancels the timer after each wait. On the tested Mac, 1,000 standalone 1 ms waits averaged 1.03 ms with this path versus 1.50 ms with plain `pselect`.

The interposer calls macOS's private `__pselect` symbol to avoid recursive dyld interposition. The QEMU byte patch is specific to UTM 4.6.5's ARM64 build. If the binary hash changes, startup fails rather than patching an unknown instruction. This path needs validation on other Macs and macOS versions; a source-level patch in UTM's QEMU fork would remove the private-symbol dependency.
