#!/usr/bin/env bash
#
# Measure what the hardware-abstraction seam costs, and prove it is nothing.
#
# Builds two roots that implement the IDENTICAL logic -- bench/seam.zig through
# the seam, bench/direct.zig as hand-written register pokes -- for two very
# different freestanding targets, at ReleaseSmall, through the pinned zig Dagger
# module. Both read their addresses and masks from bench/chip.zig, so the .text
# difference between a pair is the seam and nothing else:
#
#   cortex-m3  (thumb, Atmel SAM3X8E -- the Arduino Due)
#   cortex-a53 (aarch64, Broadcom BCM2837 -- the Raspberry Pi 3B/3B+)
#
# Two architectures because "architecture-neutral" is a claim about more than
# one machine: they differ in word size, register file, addressing and calling
# convention, and the same seam source compiles for both.
#
# The threshold is 0 bytes per architecture, and that is not aspirational --
# the seam compiles to a byte-identical instruction stream on both. A
# `comptime` seam has nothing to cost: no vtable, no function pointer, no
# indirection the compiler cannot see through. If this gate ever fails, the
# abstraction has started charging rent, and the way it charges is usually
# subtle (a value whose in-memory type does not match its in-register type
# stops promoting out of a stack slot -- see the note on `Level`'s tag type in
# hal.zig, which this benchmark is what caught).
#
# Usage:  ./measure.sh                  # report + gate at 0 bytes
#         MAX_SEAM_BYTES=8 ./measure.sh
#
# Requires the dagger CLI; no host zig toolchain.

set -euo pipefail

# The Zig toolchain pin. Keep it in sync with the `zig` toolchain pinned in the
# repo's dagger.json (the ci module); these defaults let this script also run
# standalone, without going through that module. Override with DEVEX_SHA.
DEVEX="${DEVEX:-github.com/z5labs/devex/daggerverse}"
DEVEX_SHA="${DEVEX_SHA:-bc5cee36080549722c6d3bf02152aa7d46d2dcf3}"
MOD="${DEVEX}/zig@${DEVEX_SHA}"

# The targets are fixed in build.zig; ReleaseSmall is the mode firmware ships in
# and the one where an abstraction has to earn its keep.
OPTIMIZE="${OPTIMIZE:-ReleaseSmall}"
MAX_SEAM_BYTES="${MAX_SEAM_BYTES:-0}"

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Build all four images once and pull the whole install dir out.
dagger -m "$MOD" call build \
    --source="$lib_dir" --optimize="$OPTIMIZE" --steps=bench \
    export --path="$work/out" >/dev/null

# text_of <image-name> -> prints that image's .text byte total.
text_of() {
    dagger -m "$MOD" call size --input="$work/out/bin/$1" text 2>/dev/null \
        | grep -Eo '[0-9]+' | tail -n1
}

printf '\n  optimize=%s  threshold=%d bytes of .text per architecture\n\n' \
    "$OPTIMIZE" "$MAX_SEAM_BYTES"

worst=0
for arch in cortex-m3 cortex-a53; do
    direct="$(text_of "direct-$arch")"
    seam="$(text_of "seam-$arch")"
    delta=$((seam - direct))
    [ "$delta" -gt "$worst" ] && worst="$delta"

    printf '  %-12s direct %4s bytes   seam %4s bytes   delta %+d\n' \
        "$arch" "$direct" "$seam" "$delta"
done
printf '\n'

if [ "$worst" -gt "$MAX_SEAM_BYTES" ]; then
    printf 'FAIL: the seam costs %d bytes of .text, over the %d-byte threshold --\n' \
        "$worst" "$MAX_SEAM_BYTES" >&2
    printf '      something in it is no longer resolving at compile time.\n' >&2
    exit 1
fi

printf 'OK: the seam costs %d bytes on every architecture measured.\n' "$worst"
