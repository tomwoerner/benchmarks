# Cross-platform DRAM bandwidth benchmark kit

## Recommended hierarchy

1. **Intel MLC** — deepest Intel-only diagnostic: raw bandwidth, unloaded latency, loaded latency, and read/write mixtures.
2. **STREAM** — primary vendor-neutral benchmark: Intel/AMD/ARM, raw MB/s, same C source and OpenMP kernels.
3. **PassMark PerformanceTest memory suite** — convenient packaged comparison across Windows, Linux, and macOS, including ARM64; reports raw memory subtests plus a Memory Mark score.

CPU-Z is intentionally not included. It reports memory clocks, timings, channel/SPD information and CPU benchmark scores; it does not perform a proper sustained DRAM-bandwidth benchmark.

## Linux

```bash
chmod +x run-memory-linux.sh
./run-memory-linux.sh --install-deps
```

On an Intel machine where MLC is not already installed:

```bash
./run-memory-linux.sh --install-deps --install-mlc --accept-intel-license
```

Results are stored under:

```text
~/benchmarks/memory/HOST_YYYYMMDDTHHMMSSZ/
```

## Windows x64

Run PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\run-memory-windows.ps1 -InstallDependencies
```

This installs MSYS2/GCC when needed, builds the same pinned STREAM source, runs it, and logs the result. On Intel, add `-InstallMlc -AcceptIntelLicense` to install/run MLC locally. Add `-InstallPassMark` to open the official PerformanceTest installer; rerun afterward and the script will execute the memory-only suite and export CSV/text.

## macOS Intel or Apple Silicon

Install Homebrew first, then:

```bash
chmod +x run-memory-macos.sh
./run-memory-macos.sh --install-deps
```

The script uses Homebrew GCC/OpenMP and the same pinned STREAM source.

## Optional PassMark CLI on Linux/macOS

```bash
chmod +x run-passmark-linux-macos.sh
./run-passmark-linux-macos.sh
```

On Linux, PassMark currently documents an ncurses 5 compatibility dependency. New distributions that provide only ncurses 6 may require a compatibility package. STREAM does not have that dependency and should remain the primary raw-bandwidth result.

## Comparison rules

- Keep `STREAM_ARRAY_SIZE`, `STREAM_NTIMES`, and `OMP_NUM_THREADS` identical when comparing the same hardware under different operating systems.
- Do not compare Intel MLC's “ALL Reads” directly with STREAM Triad; they are different traffic patterns.
- Compare STREAM Copy-to-Copy, Scale-to-Scale, Add-to-Add, and Triad-to-Triad.
- Record firmware, memory speed, channel population, SMT/Hyper-Threading state, power plan, and compiler version.
- Close heavy workloads and run at least three times. Keep the median result.
- Apple Silicon STREAM measures bandwidth available to CPU cores, not necessarily the full SoC/GPU unified-memory marketing bandwidth.

## Source pinning

STREAM is downloaded from commit:

```text
6703f7504a38a8da96b353cadafa64d3c2d7a2d3
```

Each run stores a SHA-256 hash of the downloaded `stream.c` alongside the executable and results.
