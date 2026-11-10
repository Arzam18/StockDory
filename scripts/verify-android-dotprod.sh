#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <aarch64-linux-android24-clang++> <build-directory>" >&2
    exit 2
fi
CXX="$1"
BUILD_DIR="$2"
HEADER="$(find "$BUILD_DIR" -path '*/include/MantaRay/Backend/ISA/NEON_DOTPROD.h' -print -quit)"
if [[ -z "$HEADER" ]]; then
    echo "ERROR: patched MantaRay NEON_DOTPROD.h was not found under $BUILD_DIR" >&2
    exit 1
fi
INCLUDE_DIR="${HEADER%/MantaRay/Backend/ISA/NEON_DOTPROD.h}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cat > "$TMP_DIR/dotprod_probe.cpp" <<'CPP'
#include <MantaRay/Backend/ISA/NEON_DOTPROD.h>
#if !defined(__aarch64__) || !defined(__ARM_FEATURE_DOTPROD)
#error "Compiler did not enable AArch64 DotProd"
#endif
using ISA = MantaRay::Backend::ISA::NEON_DOTPROD;
extern "C" __attribute__((noinline)) int32x4_t stockdory_dotprod_probe(
    int32x4_t sum, uint8x16_t input, int8x16_t weights)
{
    const auto packedInput = vreinterpretq_s16_u8(input);
    const auto packedWeights = vreinterpretq_s16_s8(weights);
    const auto result = ISA::DotU8I8(vreinterpretq_s16_s32(sum), packedInput, packedWeights);
    return vreinterpretq_s32_s16(result);
}
CPP
"$CXX" -std=c++23 -O3 -march=armv8.2-a+dotprod -S \
    -I "$INCLUDE_DIR" "$TMP_DIR/dotprod_probe.cpp" -o "$TMP_DIR/dotprod_probe.s"
if ! grep -Eiq '(^|[[:space:]])sdot[[:space:]]' "$TMP_DIR/dotprod_probe.s"; then
    echo "ERROR: generated probe assembly does not contain SDOT" >&2
    cat "$TMP_DIR/dotprod_probe.s" >&2
    exit 1
fi
echo "PASS: MantaRay's Android NEON_DOTPROD kernel emits ARM SDOT."
grep -Ein 'sdot' "$TMP_DIR/dotprod_probe.s"
