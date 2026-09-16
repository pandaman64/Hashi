#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKLOAD="${1:-find-hit}"
ELEMENTS="${2:-262144}"

case "$WORKLOAD" in
  find-hit|find-miss)
    REPETITIONS="${3:-400}"
    ;;
  insert-grow)
    REPETITIONS="${3:-50}"
    ;;
  *)
    echo "usage: $0 [find-hit|find-miss|insert-grow] [elements] [repetitions]" >&2
    exit 2
    ;;
esac

command -v lake >/dev/null || {
  echo "lake is not on PATH" >&2
  exit 127
}
command -v gprof >/dev/null || {
  echo "gprof is required (usually provided by binutils)" >&2
  exit 127
}

cd "$ROOT"
lake -f lakefile.profile.lean build hashi_profile

EXECUTABLE="$ROOT/.lake/build-profile/bin/hashi_profile"
OUTPUT_DIR="$ROOT/.lake/profiles/$WORKLOAD"
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/gmon.out" "$OUTPUT_DIR/report.txt"

(
  cd "$OUTPUT_DIR"
  "$EXECUTABLE" "$WORKLOAD" "$ELEMENTS" "$REPETITIONS"
)

gprof -b "$EXECUTABLE" "$OUTPUT_DIR/gmon.out" > "$OUTPUT_DIR/report.txt"

echo
echo "Flat-profile preview:"
awk 'NR <= 35 { print }' "$OUTPUT_DIR/report.txt"
echo
echo "Full report: $OUTPUT_DIR/report.txt"
