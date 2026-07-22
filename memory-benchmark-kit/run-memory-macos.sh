#!/usr/bin/env bash
set -Eeuo pipefail

# Native macOS STREAM runner for Intel Macs and Apple Silicon.
# Uses Homebrew GCC so the same OpenMP STREAM source/flags can be used on Linux and Windows x64.

STREAM_COMMIT="6703f7504a38a8da96b353cadafa64d3c2d7a2d3"
STREAM_ARRAY_SIZE="${STREAM_ARRAY_SIZE:-50000000}"
STREAM_NTIMES="${STREAM_NTIMES:-10}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/benchmarks/memory}"
INSTALL_DEPS=0

usage() {
  cat <<'USAGE'
Usage: ./run-memory-macos.sh [--install-deps] [--output-root PATH] [--array-size N] [--ntimes N]

--install-deps installs GCC using an existing Homebrew installation.
Homebrew itself is not installed automatically.
USAGE
}

while (($#)); do
  case "$1" in
    --install-deps) INSTALL_DEPS=1 ;;
    --output-root) OUTPUT_ROOT="$2"; shift ;;
    --array-size) STREAM_ARRAY_SIZE="$2"; shift ;;
    --ntimes) STREAM_NTIMES="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "This script is for macOS." >&2; exit 1; }
command -v brew >/dev/null || {
  echo "Homebrew is required so this can use GCC/OpenMP consistently. Install Homebrew, then rerun with --install-deps." >&2
  exit 1
}

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  brew update
  brew install gcc
fi

# Homebrew installs versioned GCC binaries such as gcc-15.
gcc_bin="$(find "$(brew --prefix)/bin" -maxdepth 1 -type f -name 'gcc-[0-9]*' -print | sort -V | tail -n 1)"
[[ -x "$gcc_bin" ]] || { echo "Homebrew GCC was not found. Re-run with --install-deps." >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
host="$(scutil --get ComputerName 2>/dev/null | tr ' /' '__' || hostname -s)"
out="$OUTPUT_ROOT/${host}_${stamp}"
tools="$out/tools"
mkdir -p "$tools"
exec > >(tee "$out/run.log") 2>&1

echo "Result directory: $out"
echo "UTC start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
  echo "=== macOS / hardware ==="
  sw_vers
  uname -a
  system_profiler SPHardwareDataType SPMemoryDataType
  echo
  echo "=== CPU ==="
  sysctl -a 2>/dev/null | grep -E 'machdep.cpu.brand_string|hw.model|hw.machine|hw.ncpu|hw.physicalcpu|hw.logicalcpu|hw.memsize' || true
  echo
  echo "=== Compiler ==="
  "$gcc_bin" --version
} > "$out/system-info.txt" 2>&1

stream_url="https://raw.githubusercontent.com/jeffhammond/STREAM/${STREAM_COMMIT}/stream.c"
curl -fL --retry 3 -o "$tools/stream.c" "$stream_url"
shasum -a 256 "$tools/stream.c" > "$tools/stream.c.sha256"

native_flag="-march=native"
[[ "$(uname -m)" == "arm64" ]] && native_flag="-mcpu=native"
stream_exe="$tools/stream-gcc"
"$gcc_bin" -O3 "$native_flag" -fopenmp \
  -DSTREAM_ARRAY_SIZE="$STREAM_ARRAY_SIZE" \
  -DNTIMES="$STREAM_NTIMES" \
  "$tools/stream.c" -o "$stream_exe"

threads="${OMP_NUM_THREADS:-$(sysctl -n hw.logicalcpu)}"
export OMP_NUM_THREADS="$threads"
export OMP_PROC_BIND="${OMP_PROC_BIND:-spread}"
export OMP_PLACES="${OMP_PLACES:-threads}"

"$stream_exe" 2>&1 | tee "$out/stream.txt"
{
  echo "benchmark,kernel,mb_per_sec"
  awk '/^(Copy|Scale|Add|Triad):/ {gsub(":","",$1); print "STREAM," $1 "," $2}' "$out/stream.txt"
} > "$out/summary.csv"

echo "Saved results: $out"
