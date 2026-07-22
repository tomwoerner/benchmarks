#!/usr/bin/env bash
set -Eeuo pipefail

# Optional third-tier runner: PassMark PerformanceTest memory suite.
# Supports command-line Linux x86_64/ARM64 and macOS Intel/Apple Silicon.
# Produces PassMark's results_memory.yml plus a terminal log.

OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/benchmarks/memory}"
os="$(uname -s)"
arch="$(uname -m)"

case "$os:$arch" in
  Linux:x86_64|Linux:amd64)
    url="https://www.passmark.com/downloads/PerformanceTest_Linux_x86-64.zip" ;;
  Linux:aarch64|Linux:arm64)
    url="https://www.passmark.com/downloads/PerformanceTest_Linux_ARM64.zip" ;;
  Darwin:x86_64|Darwin:arm64)
    url="https://www.passmark.com/downloads/PerformanceTest_Mac_CMD.zip" ;;
  *)
    echo "Unsupported OS/architecture: $os $arch" >&2; exit 1 ;;
esac

for cmd in curl unzip; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd." >&2; exit 1; }
done

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
host="$(hostname -s 2>/dev/null || hostname)"
out="$OUTPUT_ROOT/${host}_${stamp}_passmark"
tools="$out/tools"
mkdir -p "$tools"
exec > >(tee "$out/run.log") 2>&1

archive="$tools/passmark.zip"
curl -fL --retry 3 -o "$archive" "$url"
unzip -q "$archive" -d "$tools/passmark"

exe="$(find "$tools/passmark" -type f \( -name 'pt_linux*' -o -name 'pt_mac*' -o -name 'PerformanceTest*' \) -perm -u+x -print | head -n 1)"
if [[ -z "$exe" ]]; then
  exe="$(find "$tools/passmark" -type f \( -name 'pt_linux*' -o -name 'pt_mac*' -o -name 'PerformanceTest*' \) -print | head -n 1)"
  [[ -n "$exe" ]] && chmod +x "$exe"
fi
[[ -n "$exe" ]] || { echo "Could not locate the PassMark executable after extraction." >&2; exit 1; }

(
  cd "$(dirname "$exe")"
  "./$(basename "$exe")" -r 2
) 2>&1 | tee "$out/passmark-console.txt"

result="$(find "$(dirname "$exe")" -name 'results_memory.yml' -print -quit)"
if [[ -n "$result" ]]; then
  cp "$result" "$out/results_memory.yml"
  echo "Saved PassMark YAML: $out/results_memory.yml"
else
  echo "PassMark completed but results_memory.yml was not found; inspect $out/passmark-console.txt." >&2
fi

echo "Saved results: $out"
