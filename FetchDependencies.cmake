include(DownloadCPM.cmake)

CPMAddPackage(
        NAME MantaRay
        GITHUB_REPOSITORY TheBlackPlague/MantaRay
        GIT_TAG 49ee5c96f36c8fb0277d850eb9d54a205399c684
        OPTIONS
        "BUILD_TESTS OFF"
        "BUILD_BENCHMARKS OFF"
)

# Android ARM64 specialization for the pinned MantaRay version.
if (ANDROID)
    set(_mantaray_target "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/Target.h")
    set(_mantaray_neon "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/ISA/NEON.h")
    set(_mantaray_dot "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/Kernel/Dot.h")
    set(_mantaray_dotprod "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/ISA/NEON_DOTPROD.h")

    foreach(_required IN ITEMS "${_mantaray_target}" "${_mantaray_neon}" "${_mantaray_dot}")
        if (NOT EXISTS "${_required}")
            message(FATAL_ERROR "Pinned MantaRay source layout changed; missing ${_required}")
        endif ()
    endforeach ()

    # Exact u8*i8 dot products using SDOT. Inputs are biased into signed-byte
    # space (u8 - 128), then corrected with 128 * sum(weights).
    file(WRITE "${_mantaray_dotprod}" [=[
// StockDory Android specialization for ARMv8.2-A Dot Product.
// Exact full-domain u8 x i8 dot products using the architectural SDOT.
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
        [[clang::always_inline]]
        static Vector DotU8I8(const Vector sum, const Vector u8, const Vector i8)
        {
            const int8x16_t signedInput = vreinterpretq_s8_u8(
                veorq_u8(vreinterpretq_u8_s16(u8), vdupq_n_u8(0x80)));
            const int8x16_t signedWeight = vreinterpretq_s8_s16(i8);
            const int32x4_t dot = vdotq_s32(vreinterpretq_s32_s16(sum), signedInput, signedWeight);
            const int32x4_t weightSum = vdotq_s32(vdupq_n_s32(0), signedWeight, vdupq_n_s8(1));
            const int32x4_t corrected = vaddq_s32(dot, vshlq_n_s32(weightSum, 7));
            return vreinterpretq_s16_s32(corrected);
        }
    };
}
#endif
#endif // MANTARAY_BACKEND_ISA_NEON_DOTPROD_H
]=])

    file(READ "${_mantaray_target}" _mantaray_target_text)
    if (NOT _mantaray_target_text MATCHES "ISA/NEON_DOTPROD.h")
        string(FIND "${_mantaray_target_text}" "#include \"ISA/NEON.h\"" _neon_include_pos)
        if (_neon_include_pos EQUAL -1)
            message(FATAL_ERROR "Could not locate MantaRay's NEON include anchor")
        endif ()
        string(REPLACE
            "#include \"ISA/NEON.h\""
            "#include \"ISA/NEON.h\"\n#include \"ISA/NEON_DOTPROD.h\""
            _mantaray_target_text "${_mantaray_target_text}")
    endif ()
    if (NOT _mantaray_target_text MATCHES "using Native = ISA::NEON_DOTPROD")
        string(REPLACE
            "#elif defined(__ARM_NEON) && defined(__aarch64__)"
            "#elif defined(__ARM_FEATURE_DOTPROD) && defined(__ARM_NEON) && defined(__aarch64__)\n    using Native = ISA::NEON_DOTPROD;\n#elif defined(__ARM_NEON) && defined(__aarch64__)"
            _mantaray_target_text "${_mantaray_target_text}")
    endif ()
    if (NOT _mantaray_target_text MATCHES "ISA/NEON_DOTPROD.h" OR NOT _mantaray_target_text MATCHES "ISA::NEON_DOTPROD")
        message(FATAL_ERROR "Could not install MantaRay NEON DOTPROD include and backend selection")
    endif ()
    file(WRITE "${_mantaray_target}" "${_mantaray_target_text}")

    # Avoid instantiating MantaRay's consteval Block() branch for Unroll=0.
    # Match only the ternary expression, not the declaration or indentation.
    # Include real tab/newline characters in the regex class: CMake's regex
    # engine does not support POSIX [:space:] classes.
    file(READ "${_mantaray_dot}" _mantaray_dot_text)
    set(_mantaray_dot_had_crlf FALSE)
    if (_mantaray_dot_text MATCHES "\r\n")
        set(_mantaray_dot_had_crlf TRUE)
    endif ()
    string(REPLACE "\r\n" "\n" _mantaray_dot_text "${_mantaray_dot_text}")
    string(REPLACE "\r" "\n" _mantaray_dot_text "${_mantaray_dot_text}")
    string(ASCII 9 10 _mantaray_ws)
    set(_mantaray_dot_expr_pattern "Unroll[ ${_mantaray_ws}]*==[ ${_mantaray_ws}]*0[ ${_mantaray_ws}]*[?][ ${_mantaray_ws}]*Vectors[ ${_mantaray_ws}]*:[ ${_mantaray_ws}]*Block[ ${_mantaray_ws}]*\\([ ${_mantaray_ws}]*Vectors[ ${_mantaray_ws}]*,[ ${_mantaray_ws}]*K[ ${_mantaray_ws}]*,[ ${_mantaray_ws}]*Unroll[ ${_mantaray_ws}]*\\)")
    set(_mantaray_dot_expr_replacement [=[([&] { if constexpr (Unroll == 0) return Vectors; else return Block(Vectors, K, Unroll); }())]=])

    if (_mantaray_dot_text MATCHES "if constexpr \\(Unroll == 0\\) return Vectors; else return Block\\(Vectors, K, Unroll\\)")
        message(STATUS "MantaRay Dot.h already includes the Android Clang if-constexpr fix")
    else ()
        string(REGEX MATCH "${_mantaray_dot_expr_pattern}" _mantaray_dot_expr_match "${_mantaray_dot_text}")
        if (_mantaray_dot_expr_match)
            string(REGEX REPLACE "${_mantaray_dot_expr_pattern}" "${_mantaray_dot_expr_replacement}" _mantaray_dot_text "${_mantaray_dot_text}")
            if (_mantaray_dot_had_crlf)
                string(REPLACE "\n" "\r\n" _mantaray_dot_text "${_mantaray_dot_text}")
            endif ()
            file(WRITE "${_mantaray_dot}" "${_mantaray_dot_text}")
            message(STATUS "Patched MantaRay Dot.h Unroll=0 ternary for Android Clang")
        else ()
            file(STRINGS "${_mantaray_dot}" _mantaray_dot_diagnostic_lines REGEX "Step|Unroll|Block\\(")
            if (_mantaray_dot_diagnostic_lines)
                string(REPLACE ";" "\n  " _mantaray_dot_diagnostic "${_mantaray_dot_diagnostic_lines}")
            else ()
                set(_mantaray_dot_diagnostic "No lines containing Step, Unroll, or Block( were found")
            endif ()
            message(FATAL_ERROR
                "Could not patch MantaRay Dot.h for Android Clang. Expected the Unroll == 0 ? Vectors : Block(Vectors, K, Unroll) expression. Relevant source lines:\n  ${_mantaray_dot_diagnostic}")
        endif ()
    endif ()
endif ()

CPMAddPackage(
        NAME nanothread
        GITHUB_REPOSITORY TheBlackPlague/nanothread
        GIT_TAG master
)

# Bionic has no glibc pthread_getaffinity_np(); use sched_getaffinity() for
# the calling thread. Keep the patch scoped to the fetched Android dependency.
if (ANDROID AND EXISTS "${nanothread_SOURCE_DIR}/src/nanothread.cpp")
    set(_nanothread_source "${nanothread_SOURCE_DIR}/src/nanothread.cpp")
    file(READ "${_nanothread_source}" _nanothread_text)
    if (_nanothread_text MATCHES [=[pthread_getaffinity_np\(pthread_self\(\),[ 	]*size,[ 	]*cpuset\)]=])
        string(REGEX REPLACE
            [=[pthread_getaffinity_np\(pthread_self\(\),[ 	]*size,[ 	]*cpuset\)]=]
            "sched_getaffinity(0, size, cpuset)"
            _nanothread_text "${_nanothread_text}")
        if (NOT _nanothread_text MATCHES [=[#[ 	]*include[ 	]*[<"]sched\.h[>"]]=])
            string(REPLACE "#include <thread>" "#include <thread>\n#include <sched.h>" _nanothread_text "${_nanothread_text}")
        endif ()
        file(WRITE "${_nanothread_source}" "${_nanothread_text}")
        message(STATUS "Patched nanothread CPU affinity for Android Bionic")
    elseif (_nanothread_text MATCHES [=[sched_getaffinity\(0,]=])
        message(STATUS "nanothread already uses sched_getaffinity()")
    else ()
        message(FATAL_ERROR "Could not patch nanothread CPU affinity for Android Bionic")
    endif ()
endif ()
