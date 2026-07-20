#!/usr/bin/env bash
#
# Measure the flash cost of an assertion and prove it is a bare trap.
#
# Builds four bench roots for a real MCU target (Cortex-M3, thumb /
# freestanding) at ReleaseSmall through the pinned zig Dagger module, reads the
# .text size of each, and reports the per-assertion cost from two matched
# on/off pairs:
#
#   - (on8  - off8)  / 8   bytes per assertion
#   - (on16 - off16) / 16  bytes per assertion
#
# Each pair is identical but for whether the asserts are compiled in, so the
# delta is the cost of the assertions and nothing else, and the two sizes
# confirm that cost is flat as the count grows. If a failed assertion pulled in
# formatting, an unwinder, or panic plumbing, the cost would be measured in
# hundreds of bytes to kilobytes; a bare trap is a handful. So this script also
# gates: it exits non-zero if either figure exceeds MAX_BYTES_PER_ASSERT, which
# is what makes it usable as a CI check as well as a report.
#
# Usage:  ./measure.sh            # report + gate with the default threshold
#         MAX_BYTES_PER_ASSERT=24 ./measure.sh
#
# Requires the dagger CLI; no host zig toolchain.

set -euo pipefail

# The toolchain pin. CI exports DEVEX/DEVEX_SHA from ci.yaml so the pin lives
# in one place; the defaults here let the script run standalone.
DEVEX="${DEVEX:-github.com/z5labs/devex/daggerverse}"
DEVEX_SHA="${DEVEX_SHA:-bc5cee36080549722c6d3bf02152aa7d46d2dcf3}"
MOD="${DEVEX}/zig@${DEVEX_SHA}"

# The target is fixed in build.zig (a representative Cortex-M3), not special:
# any freestanding target shows the same shape because @trap() lowers to the
# target's own trap instruction.
OPTIMIZE="${OPTIMIZE:-ReleaseSmall}"
MAX_BYTES_PER_ASSERT="${MAX_BYTES_PER_ASSERT:-32}"

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Build all three benchmark images once and pull the whole install dir out.
dagger -m "$MOD" call build \
    --source="$lib_dir" --optimize="$OPTIMIZE" --steps=bench \
    export --path="$work/out" >/dev/null

# text_of <root-name> -> prints the .text byte total of that bench image.
text_of() {
    dagger -m "$MOD" call size --input="$work/out/bin/$1" text 2>/dev/null \
        | grep -Eo '[0-9]+' | tail -n1
}

off8="$(text_of off8)"
on8="$(text_of on8)"
off16="$(text_of off16)"
on16="$(text_of on16)"

per8=$(((on8 - off8) / 8))
per16=$(((on16 - off16) / 16))
worst=$((per8 > per16 ? per8 : per16))

printf '\n'
printf '  target=thumb-freestanding-eabi (Cortex-M3)  optimize=%s\n\n' "$OPTIMIZE"
printf '  %-28s %6s bytes (.text)\n' "off8   (8 asserts, disabled)" "$off8"
printf '  %-28s %6s bytes (.text)\n' "on8    (8 asserts, enabled)" "$on8"
printf '  %-28s %6s bytes (.text)\n' "off16  (16 asserts, disabled)" "$off16"
printf '  %-28s %6s bytes (.text)\n' "on16   (16 asserts, enabled)" "$on16"
printf '  ----\n'
printf '  per assertion (from 8) : %d bytes\n' "$per8"
printf '  per assertion (from 16): %d bytes\n' "$per16"
printf '  threshold              : %d bytes/assertion\n\n' "$MAX_BYTES_PER_ASSERT"

if [ "$worst" -gt "$MAX_BYTES_PER_ASSERT" ]; then
    printf 'FAIL: %d bytes/assertion exceeds %d -- a failed assertion is pulling in\n' \
        "$worst" "$MAX_BYTES_PER_ASSERT" >&2
    printf '      more than a bare trap (formatting/unwind/panic machinery?).\n' >&2
    exit 1
fi

printf 'OK: a failed assertion lowers to a bare trap (%d bytes each).\n' "$worst"
