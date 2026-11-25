# StockDory Android ARM64 port (upstream source adaptation)

## Source baseline

This port is based on the uploaded newer upstream `StockDory-master(new).zip`, not the older Android fork. The upstream engine source and its current `Eclipse-2715d6146c.nnue` model are retained. The older Android fork's `Eclipse-0e72a60543.nnue`, legacy engine files, `NetworkArchitecture.h`, `Backend/` tree, External headers, and older MantaRay integration are not transplanted.

## Android build targets

- Android ABI: `arm64-v8a`
- Android API: 24
- Android NDK: r27c (`27.2.12479018`)
- C++ standard: C++23 (as required by upstream)
- C++ runtime: static (`c++_static`)
- Baseline: `-march=armv8-a`, native MantaRay NEON backend
- DotProd: `-march=armv8.2-a+dotprod`, MantaRay NEON_DOTPROD backend
- No `uci_date` workflow input or UCI-date source injection

## MantaRay adaptation

Upstream MantaRay is pinned by the upstream source to commit `7d240a33868e751f4d97619d6903c1c0e8bdbad6`. That revision uses `MantaRay::Lowering::Target` plus `MantaRay::Backend::ISAOf`, rather than the older `Backend/Target.h` structure patched by the previous Android fork.

The Android CMake integration adds a `NEON_DOTPROD` ISA implementation into that dependency checkout and wires it through:

- `include/MantaRay/Lowering/Target.h`
- `include/MantaRay/Backend/ISA/ISAOf.h`
- `include/MantaRay/Backend/ISA/NEON_DOTPROD.h`

The DotProd kernel implements exact unsigned-byte × signed-byte dot products over the full u08 domain. It centers each unsigned input byte by 128, applies architectural `SDOT`, then adds `128 * sum(weights)` per accumulator lane. This avoids signed-byte truncation of unsigned inputs and preserves the original integer result. The ISA advertises `VNNI=true` and `PairDot=true` to select MantaRay's exact Dpbusd/PackusDot path where its lowering proves that path valid.

The upstream Eclipse graph uses i16 weights in its declared affine layers. Therefore the DotProd-capable backend is selected and separately verified, but the engine's current model may not instantiate any u08×i08 stage; the SDOT probe validates that the backend kernel emits `sdot`, not that every evaluation call in this model executes SDOT. Do not assume a performance gain without comparing NPS on the target device.

## Build workflow

`.github/workflows/android.yml` builds and uploads baseline NEON first, then the separate DotProd binary. It checks AArch64 ELF identity, Android `linker64`, the absence of `libc++_shared.so`, compile-time backend selection, and emitted NEON/SDOT instructions from the actual MantaRay kernels.

## Local validation performed (not a full Android build)

- CMake configuration/generation completed for both NEON and DotProd Android option sets using fixture dependency targets and the pinned MantaRay API's exact insertion anchors.
- Re-running the MantaRay CMake patch was idempotent.
- AArch64 Android-target Clang 17 compilation of the generated DotProd ISA kernel passed; emitted assembly contains `sdot`.
- A baseline ARMv8-A NEON kernel instruction probe emitted widening/accumulate instructions and no `sdot`.
- The unsigned-byte centering/correction identity was checked against direct u08×i08 products for 100,000 random vectors.
- The workflow YAML, embedded Bash steps, and SIMD verification script passed syntax checks.

## Not yet validated

The local environment does not include Android NDK r27c or a network connection for fetching the pinned CPM dependencies. The CMake configuration tests use fixture dependency targets; they do not compile the full StockDory translation unit against the downloaded MantaRay checkout. The complete Android NDK build, actual network initialization, Android runtime, NPS and playing strength therefore remain pending GitHub Actions and device testing. The CMake-time MantaRay source patch is pinned to the upstream commit and fails explicitly if the expected new API layout or insertion anchors change.
