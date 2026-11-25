#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <aarch64-android-clang++> <build-directory> <neon|dotprod>" >&2
    exit 2
fi

CXX="$1"
BUILD_DIR="$2"
MODE="$3"
HEADER="$(find "$BUILD_DIR" -path '*/include/MantaRay/Backend/ISA/NEON.h' -print -quit)"
if [[ -z "$HEADER" ]]; then
    echo "ERROR: MantaRay NEON.h not found under $BUILD_DIR" >&2
    exit 1
fi
INCLUDE_DIR="${HEADER%/MantaRay/Backend/ISA/NEON.h}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

case "$MODE" in
    neon)
        ISA_HEADER='MantaRay/Backend/ISA/NEON.h'
        ISA_TYPE='MantaRay::Backend::ISA::NEON'
        ARCH='armv8-a'
        ;;
    dotprod)
        ISA_HEADER='MantaRay/Backend/ISA/NEON_DOTPROD.h'
        ISA_TYPE='MantaRay::Backend::ISA::NEON_DOTPROD'
        ARCH='armv8.2-a+dotprod'
        test -f "$INCLUDE_DIR/$ISA_HEADER"
        ;;
    *)
        echo "Unknown SIMD mode: $MODE" >&2
        exit 2
        ;;
esac

cat > "$TMP_DIR/probe.cpp" <<CPP
#include <arm_neon.h>
#include <$ISA_HEADER>
#if !defined(__aarch64__) || !defined(__ARM_NEON)
#error "Compiler did not enable AArch64 NEON"
#endif
#if defined(STOCKDORY_EXPECT_DOTPROD) && !defined(__ARM_FEATURE_DOTPROD)
#error "Compiler did not enable ARM FEAT_DOTPROD"
#endif
extern "C" __attribute__((noinline)) int32x4_t stockdory_simd_probe(
    int32x4_t sum, uint8x16_t input, int8x16_t weights)
{
    const auto result = $ISA_TYPE::DotU08I08(
        vreinterpretq_s16_s32(sum),
        vreinterpretq_s16_u8(input),
        vreinterpretq_s16_s8(weights));
    return vreinterpretq_s32_s16(result);
}
CPP

EXTRA=()
if [[ "$MODE" == "dotprod" ]]; then
    EXTRA+=(-DSTOCKDORY_EXPECT_DOTPROD=1)
fi
"$CXX" -std=c++23 -O3 "-march=$ARCH" "${EXTRA[@]}" \
    -I "$INCLUDE_DIR" -S "$TMP_DIR/probe.cpp" -o "$TMP_DIR/probe.s"

if [[ "$MODE" == "dotprod" ]]; then
    if ! grep -Eiq '(^|[[:space:]])sdot[[:space:]]' "$TMP_DIR/probe.s"; then
        echo "ERROR: DotProd kernel assembly does not contain SDOT" >&2
        cat "$TMP_DIR/probe.s" >&2
        exit 1
    fi
    echo "PASS: MantaRay NEON_DOTPROD emits SDOT."
    grep -Ein 'sdot' "$TMP_DIR/probe.s"
else
    if grep -Eiq '(^|[[:space:]])sdot[[:space:]]' "$TMP_DIR/probe.s"; then
        echo "ERROR: baseline NEON probe unexpectedly contains SDOT" >&2
        exit 1
    fi
    if ! grep -Eiq '\b(ushll|ushll2|sshll|sshll2|sadalp|sqadd|smull|umull)\b' "$TMP_DIR/probe.s"; then
        echo "ERROR: baseline NEON probe did not emit expected NEON widening/accumulate instructions" >&2
        cat "$TMP_DIR/probe.s" >&2
        exit 1
    fi
    echo "PASS: baseline MantaRay NEON kernel emits ARM NEON widening/accumulate instructions and no SDOT."
fi
