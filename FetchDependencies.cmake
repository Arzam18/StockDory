include(DownloadCPM.cmake)

CPMAddPackage(
        NAME MantaRay
        GITHUB_REPOSITORY TheBlackPlague/MantaRay
        GIT_TAG 49ee5c96f36c8fb0277d850eb9d54a205399c684
        OPTIONS
        "BUILD_TESTS OFF"
        "BUILD_BENCHMARKS OFF"
)

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
