#!/usr/bin/env bash
set -Eeuo pipefail

# Cross-platform memory benchmark runner for Linux.
# - STREAM: vendor-neutral (Intel/AMD/ARM), raw MB/s
# - Intel MLC: optional Intel-only bandwidth + latency detail
# Results are written under ~/benchmarks/memory by default.

STREAM_COMMIT="6703f7504a38a8da96b353cadafa64d3c2d7a2d3"
STREAM_ARRAY_SIZE="${STREAM_ARRAY_SIZE:-50000000}"   # 381.5 MiB/array, ~1.12 GiB total
STREAM_NTIMES="${STREAM_NTIMES:-10}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/benchmarks/memory}"
INSTALL_DEPS=0
INSTALL_MLC=0
ACCEPT_INTEL_LICENSE=0
SKIP_MLC=0

usage() {
  cat <<'USAGE'
Usage: ./run-memory-linux.sh [options]

Options:
  --install-deps          Install compiler/curl prerequisites using the detected package manager.
  --install-mlc           Download Intel MLC 3.12 locally and install mlc in /usr/local/bin.
  --accept-intel-license  Required with --install-mlc. Download/use means accepting Intel's license.
  --skip-mlc              Run only STREAM even when mlc is installed.
  --output-root PATH      Root directory for timestamped results.
  --array-size N          STREAM elements per array (default 50,000,000; ~1.12 GiB total).
  --ntimes N              STREAM repetitions (default 10).
  -h, --help              Show this help.

Examples:
  ./run-memory-linux.sh --install-deps
  ./run-memory-linux.sh --install-deps --install-mlc --accept-intel-license
  STREAM_ARRAY_SIZE=100000000 OMP_NUM_THREADS=32 ./run-memory-linux.sh
USAGE
}

while (($#)); do
  case "$1" in
    --install-deps) INSTALL_DEPS=1 ;;
    --install-mlc) INSTALL_MLC=1 ;;
    --accept-intel-license) ACCEPT_INTEL_LICENSE=1 ;;
    --skip-mlc) SKIP_MLC=1 ;;
    --output-root) OUTPUT_ROOT="$2"; shift ;;
    --array-size) STREAM_ARRAY_SIZE="$2"; shift ;;
    --ntimes) STREAM_NTIMES="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for value in "$STREAM_ARRAY_SIZE" "$STREAM_NTIMES"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "Array size and ntimes must be positive integers." >&2; exit 2; }
done

install_deps() {
  if command -v apt-get >/dev/null; then
    sudo apt-get update
    sudo apt-get install -y build-essential curl ca-certificates pciutils dmidecode
  elif command -v dnf >/dev/null; then
    sudo dnf install -y gcc gcc-c++ make libgomp curl ca-certificates pciutils dmidecode
  elif command -v yum >/dev/null; then
    sudo yum install -y gcc gcc-c++ make libgomp curl ca-certificates pciutils dmidecode
  elif command -v pacman >/dev/null; then
    sudo pacman -Syu --needed --noconfirm base-devel curl ca-certificates pciutils dmidecode
  elif command -v zypper >/dev/null; then
    sudo zypper --non-interactive install gcc make libgomp1 curl ca-certificates pciutils dmidecode
  else
    echo "Unsupported package manager. Install GCC with OpenMP, curl, and ca-certificates manually." >&2
    exit 1
  fi
}

install_mlc() {
  [[ "$ACCEPT_INTEL_LICENSE" -eq 1 ]] || {
    echo "Refusing MLC download: add --accept-intel-license after reviewing Intel's license." >&2
    exit 2
  }
  local archive="/tmp/mlc_v3.12.tgz"
  local extract="$HOME/.local/opt/mlc_v3.12"
  curl -fL --retry 3 -o "$archive" "https://downloadmirror.intel.com/866182/mlc_v3.12.tgz"
  echo "4b8f7685d71998dd5d445432ab40c2115158462bfcd359113ae551a84e250c50  $archive" | sha256sum --check
  rm -rf "$extract"
  mkdir -p "$extract"
  tar -xzf "$archive" -C "$extract"
  local binary
  binary="$(find "$extract" -type f -path '*/Linux/mlc' -print -quit)"
  [[ -n "$binary" ]] || { echo "Could not find Linux/mlc after extraction." >&2; exit 1; }
  sudo install -m 0755 "$binary" /usr/local/bin/mlc
}

[[ "$INSTALL_DEPS" -eq 1 ]] && install_deps
[[ "$INSTALL_MLC" -eq 1 ]] && install_mlc

for cmd in gcc curl; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd. Re-run with --install-deps." >&2; exit 1; }
done

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
host="$(hostname -s 2>/dev/null || hostname)"
out="$OUTPUT_ROOT/${host}_${stamp}"
tools="$out/tools"
mkdir -p "$tools"

# Log the complete run while preserving separate raw result files below.
exec > >(tee "$out/run.log") 2>&1

echo "Result directory: $out"
echo "UTC start: $(date -u --iso-8601=seconds)"
echo "STREAM source commit: $STREAM_COMMIT"
echo "STREAM_ARRAY_SIZE=$STREAM_ARRAY_SIZE"
echo "STREAM_NTIMES=$STREAM_NTIMES"

{
  echo "=== OS ==="
  uname -a
  command -v hostnamectl >/dev/null && hostnamectl || true
  echo
  echo "=== CPU / topology ==="
  lscpu || true
  echo
  echo "=== Memory ==="
  free -h || true
  command -v lsmem >/dev/null && lsmem || true
  echo
  echo "=== DIMMs (requires sudo) ==="
  command -v dmidecode >/dev/null && sudo dmidecode --type memory || true
  echo
  echo "=== Compiler ==="
  gcc --version
} > "$out/system-info.txt" 2>&1

stream_url="https://raw.githubusercontent.com/jeffhammond/STREAM/${STREAM_COMMIT}/stream.c"
curl -fL --retry 3 -o "$tools/stream.c" "$stream_url"
sha256sum "$tools/stream.c" > "$tools/stream.c.sha256"

native_flag="-march=native"
case "$(uname -m)" in
  aarch64|arm64) native_flag="-mcpu=native" ;;
esac

stream_exe="$tools/stream-gcc"
gcc -O3 "$native_flag" -fopenmp \
  -DSTREAM_ARRAY_SIZE="$STREAM_ARRAY_SIZE" \
  -DNTIMES="$STREAM_NTIMES" \
  "$tools/stream.c" -o "$stream_exe"

threads="${OMP_NUM_THREADS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)}"
export OMP_NUM_THREADS="$threads"
export OMP_PROC_BIND="${OMP_PROC_BIND:-spread}"
export OMP_PLACES="${OMP_PLACES:-threads}"

echo
echo "=== STREAM: vendor-neutral raw bandwidth ==="
echo "OMP_NUM_THREADS=$OMP_NUM_THREADS OMP_PROC_BIND=$OMP_PROC_BIND OMP_PLACES=$OMP_PLACES"
"$stream_exe" 2>&1 | tee "$out/stream.txt"

{
  echo "benchmark,kernel,mb_per_sec"
  awk '/^(Copy|Scale|Add|Triad):/ {gsub(":","",$1); print "STREAM," $1 "," $2}' "$out/stream.txt"
} > "$out/summary.csv"

cpu_vendor="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
if [[ "$SKIP_MLC" -eq 0 && "$cpu_vendor" == "GenuineIntel" ]] && command -v mlc >/dev/null; then
  echo
  echo "=== Intel MLC: Intel-specific bandwidth and latency ==="
  sudo modprobe msr
  for test in max_bandwidth peak_injection_bandwidth loaded_latency idle_latency; do
    echo
    echo "--- mlc --$test ---"
    sudo mlc "--$test" 2>&1 | tee "$out/mlc-$test.txt"
  done
elif [[ "$SKIP_MLC" -eq 0 && "$cpu_vendor" == "GenuineIntel" ]]; then
  echo "Intel CPU detected, but mlc was not found. Use --install-mlc --accept-intel-license to add it."
elif [[ "$SKIP_MLC" -eq 0 ]]; then
  echo "Skipping Intel MLC because CPU vendor is '$cpu_vendor'. STREAM remains valid."
fi

echo
echo "UTC finish: $(date -u --iso-8601=seconds)"
echo "Saved results: $out"
