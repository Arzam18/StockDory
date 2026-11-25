include(DownloadCPM.cmake)

CPMAddPackage(
        NAME MantaRay
        GITHUB_REPOSITORY TheBlackPlague/MantaRay
        GIT_TAG 7d240a33868e751f4d97619d6903c1c0e8bdbad6
        OPTIONS
        "BUILD_EXAMPLES OFF"
)

# Clang in Android NDK r27c needs narrow source-compatibility fixes in this
# pinned MantaRay revision. These preserve compile-time evaluation and do not
# alter the network graph, lowering decisions, or arithmetic.
function(stockdory_patch_mantaray_file path old_text new_text description)
    file(READ "${path}" _source)
    string(FIND "${_source}" "${old_text}" _old_position)
    if (_old_position EQUAL -1)
        string(FIND "${_source}" "${new_text}" _new_position)
        if (_new_position EQUAL -1)
            message(FATAL_ERROR "MantaRay compatibility patch anchor missing (${description}): ${path}")
        endif ()
        return()
    endif ()
    string(REPLACE "${old_text}" "${new_text}" _patched "${_source}")
    file(WRITE "${path}" "${_patched}")
endfunction()

# The upstream MantaRay revision uses Lowering::Target + Backend::ISAOf
# (the older Android port patched the retired Backend/Target.h API). Add an
# exact ARMv8.2-A DotProd ISA implementation to this pinned dependency checkout.
if (ANDROID)
    set(_mantaray_lowering_target "${MantaRay_SOURCE_DIR}/include/MantaRay/Lowering/Target.h")
    set(_mantaray_isaof "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/ISA/ISAOf.h")
    set(_mantaray_neon "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/ISA/NEON.h")
    set(_mantaray_dotprod "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/ISA/NEON_DOTPROD.h")
    set(_mantaray_model "${MantaRay_SOURCE_DIR}/include/MantaRay/Model.h")
    set(_mantaray_update "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/Kernel/Update.h")
    set(_mantaray_network "${MantaRay_SOURCE_DIR}/include/MantaRay/Runtime/Network.h")

    foreach (_required IN ITEMS
        "${_mantaray_lowering_target}" "${_mantaray_isaof}" "${_mantaray_neon}"
        "${_mantaray_model}" "${_mantaray_update}" "${_mantaray_network}"
    )
        if (NOT EXISTS "${_required}")
            message(FATAL_ERROR "Pinned MantaRay source layout changed; missing ${_required}")
        endif ()
    endforeach ()

    stockdory_patch_mantaray_file(
        "${_mantaray_model}"
        [=[        template<auto>
        constexpr inline bool Rejected = false;
        template<Lines<0> R>
        constexpr inline bool Rejected<R> = true;]=]
        [=[        template<auto R>
        constexpr inline bool Rejected =
            std::is_same_v<std::remove_cv_t<decltype(R)>, Lines<0>>;]=]
        "Clang-compatible MantaRay diagnostic-report type check"
    )
    stockdory_patch_mantaray_file(
        "${_mantaray_update}"
        "consteval s00 Tile(const s00 vectors, const s00 limit)"
        "constexpr s00 Tile(const s00 vectors, const s00 limit)"
        "MantaRay update-kernel tile helper"
    )
    stockdory_patch_mantaray_file(
        "${_mantaray_network}"
        "consteval Rational HeadFactor(const Rational head, const Rational scale)"
        "constexpr Rational HeadFactor(const Rational head, const Rational scale)"
        "MantaRay head-factor helper"
    )

    file(WRITE "${_mantaray_dotprod}" [=[
// StockDory Android ARM64 specialization for ARMv8.2-A FEAT_DOTPROD.
// Exact full-domain u08*i08 products: (u08 - 128) * i08 + 128 * sum(i08).
#ifndef MANTARAY_BACKEND_ISA_NEON_DOTPROD_H
#define MANTARAY_BACKEND_ISA_NEON_DOTPROD_H

#if defined(__ARM_FEATURE_DOTPROD) && defined(__ARM_NEON) && defined(__aarch64__)
#include <arm_neon.h>
#include "NEON.h"

namespace MantaRay::Backend::ISA
{
    struct NEON_DOTPROD : NEON
    {
        constexpr static bool VNNI = true;
        constexpr static bool PairDot = true;

        [[clang::always_inline]]
        static Vector DotU08I08(const Vector sum, const Vector u8, const Vector i8) noexcept
        {
            const int8x16_t input = vreinterpretq_s8_u8(
                veorq_u8(vreinterpretq_u8_s16(u8), vdupq_n_u8(0x80)));
            const int8x16_t weights = vreinterpretq_s8_s16(i8);

            const int32x4_t dot = vdotq_s32(vreinterpretq_s32_s16(sum), input, weights);
            const int32x4_t weightSum = vdotq_s32(
                vdupq_n_s32(0), weights, vdupq_n_s8(1));
            const int32x4_t corrected = vaddq_s32(dot, vshlq_n_s32(weightSum, 7));

            return vreinterpretq_s16_s32(corrected);
        }
    };
}
#endif

#endif // MANTARAY_BACKEND_ISA_NEON_DOTPROD_H
]=])

    # Add the ARM DotProd target and prefer it over baseline NEON only when
    # the compiler target actually defines FEAT_DOTPROD.
    file(READ "${_mantaray_lowering_target}" _lowering_target_text)
    if (NOT _lowering_target_text MATCHES "Target NEON_DOTPROD")
        set(_target_anchor "#if   defined(MANTARAY_FORCE_SCALAR)")
        set(_target_definition [=[#if defined(__ARM_FEATURE_DOTPROD) && defined(__ARM_NEON) && defined(__aarch64__)
    constexpr inline Target NEON_DOTPROD {
        .Name        = "NEON_DOTPROD",
        .Bytes       = 16,
        .Registers   = 32,
        .DotChains   = 2,
        .DotInFlight = 1,
        .VNNI        = true
    };
#endif

]=])
        string(FIND "${_lowering_target_text}" "${_target_anchor}" _target_anchor_pos)
        if (_target_anchor_pos EQUAL -1)
            message(FATAL_ERROR "Could not locate MantaRay Lowering::Target native-selection anchor")
        endif ()
        string(REPLACE "${_target_anchor}" "${_target_definition}${_target_anchor}" _lowering_target_text "${_lowering_target_text}")
    endif ()
    if (NOT _lowering_target_text MATCHES "Native = NEON_DOTPROD")
        set(_neon_native_anchor "#elif defined(__ARM_NEON) && defined(__aarch64__)")
        set(_neon_native_replacement [=[#elif defined(__ARM_FEATURE_DOTPROD) && defined(__ARM_NEON) && defined(__aarch64__)
    constexpr inline const Target& Native = NEON_DOTPROD;
#elif defined(__ARM_NEON) && defined(__aarch64__)]=])
        string(FIND "${_lowering_target_text}" "${_neon_native_anchor}" _neon_native_pos)
        if (_neon_native_pos EQUAL -1)
            message(FATAL_ERROR "Could not locate MantaRay ARM64 NEON native-selection branch")
        endif ()
        string(REPLACE "${_neon_native_anchor}" "${_neon_native_replacement}" _lowering_target_text "${_lowering_target_text}")
    endif ()
    if (NOT _lowering_target_text MATCHES "Target NEON_DOTPROD" OR NOT _lowering_target_text MATCHES "Native = NEON_DOTPROD")
        message(FATAL_ERROR "Could not install MantaRay NEON DotProd target selection")
    endif ()
    file(WRITE "${_mantaray_lowering_target}" "${_lowering_target_text}")

    # Bind the target to its ISA implementation through the new API.
    file(READ "${_mantaray_isaof}" _isaof_text)
    if (NOT _isaof_text MATCHES "NEON_DOTPROD.h")
        set(_isaof_include_anchor [=[#include "NEON.h"]=])
        set(_isaof_include_replacement [=[#include "NEON.h"
#include "NEON_DOTPROD.h"]=])
        string(FIND "${_isaof_text}" "${_isaof_include_anchor}" _neon_include_pos)
        if (_neon_include_pos EQUAL -1)
            message(FATAL_ERROR "Could not locate MantaRay ISAOf NEON include anchor")
        endif ()
        string(REPLACE "${_isaof_include_anchor}" "${_isaof_include_replacement}" _isaof_text "${_isaof_text}")
    endif ()
    if (NOT _isaof_text MATCHES "ISAOf<Lowering::NEON_DOTPROD>")
        set(_neon_mapping [=[#if defined(__ARM_FEATURE_DOTPROD) && defined(__ARM_NEON) && defined(__aarch64__)
        template<>
        struct ISAOf<Lowering::NEON_DOTPROD> { using Type = ISA::NEON_DOTPROD; };
#endif

]=])
        set(_neon_mapping_anchor "#if defined(__ARM_NEON) && defined(__aarch64__)")
        string(FIND "${_isaof_text}" "${_neon_mapping_anchor}" _isaof_mapping_pos)
        if (_isaof_mapping_pos EQUAL -1)
            message(FATAL_ERROR "Could not locate MantaRay ISAOf NEON mapping anchor")
        endif ()
        string(REPLACE "${_neon_mapping_anchor}" "${_neon_mapping}${_neon_mapping_anchor}" _isaof_text "${_isaof_text}")
    endif ()
    if (NOT _isaof_text MATCHES "NEON_DOTPROD.h" OR NOT _isaof_text MATCHES "ISAOf<Lowering::NEON_DOTPROD>")
        message(FATAL_ERROR "Could not install MantaRay NEON DotProd ISA mapping")
    endif ()
    file(WRITE "${_mantaray_isaof}" "${_isaof_text}")
endif ()

CPMAddPackage(
        NAME fastrange
        GITHUB_REPOSITORY lemire/fastrange
        GIT_TAG f6e712b4725fc9443a11516a6302f5220e0ed951
        DOWNLOAD_ONLY YES
)

CPMAddPackage(
        NAME strutil
        GITHUB_REPOSITORY Shot511/strutil
        GIT_TAG dafb13e8e5e7761dc9a731862a666221e82cd546
        DOWNLOAD_ONLY YES
)
