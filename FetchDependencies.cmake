include(DownloadCPM.cmake)

CPMAddPackage(
        NAME MantaRay
        GITHUB_REPOSITORY TheBlackPlague/MantaRay
        GIT_TAG 49ee5c96f36c8fb0277d850eb9d54a205399c684
        OPTIONS
        "BUILD_TESTS OFF"
        "BUILD_BENCHMARKS OFF"
)

# Clang from the Android NDK rejects MantaRay's conditional expression when
# one branch calls the consteval Block() helper with Unroll == 0. An if-constexpr
# inside a constexpr lambda discards that branch at template instantiation.
# Keep this narrowly scoped to Android so desktop builds use upstream unchanged.
if (ANDROID AND EXISTS "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/Kernel/Dot.h")
    set(_mantaray_dot "${MantaRay_SOURCE_DIR}/include/MantaRay/Backend/Kernel/Dot.h")
    file(READ "${_mantaray_dot}" _mantaray_dot_text)
    set(_mantaray_dot_old "constexpr s00  Step    = Unroll == 0 ? Vectors : Block(Vectors, K, Unroll);")
    set(_mantaray_dot_new "constexpr s00 Step = [&] { if constexpr (Unroll == 0) return Vectors; else return Block(Vectors, K, Unroll); }();")
    string(FIND "${_mantaray_dot_text}" "${_mantaray_dot_old}" _mantaray_dot_match)
    if (NOT _mantaray_dot_match EQUAL -1)
        string(REPLACE "${_mantaray_dot_old}" "${_mantaray_dot_new}" _mantaray_dot_text "${_mantaray_dot_text}")
        file(WRITE "${_mantaray_dot}" "${_mantaray_dot_text}")
        message(STATUS "Patched MantaRay Dot.h consteval branch for Android Clang")
    elseif (_mantaray_dot_text MATCHES "if constexpr")
        message(STATUS "MantaRay Dot.h already has an if-constexpr branch")
    else ()
        message(FATAL_ERROR "Could not apply Android MantaRay Dot.h compatibility patch; inspect the pinned MantaRay revision")
    endif ()
endif ()

CPMAddPackage(
        NAME nanothread
        GITHUB_REPOSITORY TheBlackPlague/nanothread
        GIT_TAG master
)

# Android bionic does not provide glibc's pthread_getaffinity_np().
# nanothread uses it only to read the current thread's CPU affinity; Linux's
# sched_getaffinity(0, ...) provides the equivalent current-thread operation.
if (ANDROID AND EXISTS "${nanothread_SOURCE_DIR}/src/nanothread.cpp")
    set(_nanothread_source "${nanothread_SOURCE_DIR}/src/nanothread.cpp")
    file(READ "${_nanothread_source}" _nanothread_text)
    if (_nanothread_text MATCHES [=[pthread_getaffinity_np\(pthread_self\(\),[ ]*size,[ ]*cpuset\)]=])
        string(REGEX REPLACE
            [=[pthread_getaffinity_np\(pthread_self\(\),[ ]*size,[ ]*cpuset\)]=]
            "sched_getaffinity(0, size, cpuset)"
            _nanothread_text "${_nanothread_text}")
        if (NOT _nanothread_text MATCHES [=[#[ ]*include[ ]*[<"]sched\.h[>"]]=])
            string(REPLACE "#include <pthread.h>" "#include <pthread.h>\n#include <sched.h>" _nanothread_text "${_nanothread_text}")
        endif ()
        file(WRITE "${_nanothread_source}" "${_nanothread_text}")
        message(STATUS "Patched nanothread affinity query for Android bionic")
    else ()
        message(STATUS "nanothread affinity call not matched; checking whether upstream already supports Android")
    endif ()
endif ()
