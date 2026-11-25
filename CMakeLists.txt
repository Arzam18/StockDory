cmake_minimum_required(VERSION 3.21)

project(StockDory LANGUAGES CXX)

set(CMAKE_CXX_STANDARD          23 )
set(CMAKE_CXX_STANDARD_REQUIRED ON )
set(CMAKE_CXX_EXTENSIONS        OFF)

set(CMAKE_CXX_FLAGS         "${CMAKE_CXX_FLAGS} -flto=full" )
set(CMAKE_CXX_FLAGS_DEBUG   "-Wall -Wextra -g -ftime-report")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG"                  )

if (NOT APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -mno-avx512vnni")
endif ()

set(VERSION  "0.5"  )
set(CODENAME "Moray")

option(BUILD_NATIVE     "Build with native optimizations enabled"          ON )
option(BUILD_PGO        "Build with Profile Guided Optimization"           OFF)
option(BUILD_CI         "Build for CI - BUILD_NATIVE/BUILD_PGO is ignored" OFF)
option(BUILD_TUNING     "Build with tunable UCI parameters"                OFF)
option(BUILD_PRODUCTION "Build for production - Version is solidified"     OFF)

# Android ARM64 backend selection. DotProd is a separate binary because it
# requires ARMv8.2-A FEAT_DOTPROD at runtime.
option(STOCKDORY_EXPECT_DOTPROD "Require the Android ARM64 NEON DotProd backend" OFF)

if (STOCKDORY_EXPECT_DOTPROD)
    if (NOT ANDROID)
        message(FATAL_ERROR "STOCKDORY_EXPECT_DOTPROD is only supported for Android builds")
    endif ()
    if (NOT ARCHITECTURE MATCHES "dotprod")
        message(FATAL_ERROR "STOCKDORY_EXPECT_DOTPROD requires ARCHITECTURE=armv8.2-a+dotprod")
    endif ()
endif ()

if (ANDROID AND ARCHITECTURE MATCHES "dotprod" AND NOT STOCKDORY_EXPECT_DOTPROD)
    message(FATAL_ERROR "A DotProd Android target must set STOCKDORY_EXPECT_DOTPROD=ON")
endif ()

set(RELEASE_FILE  "${CMAKE_CURRENT_SOURCE_DIR}/.stockdory-release")
set(REVISION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/.stockdory-revision")

if (EXISTS "${RELEASE_FILE}")
    set(BUILD_PRODUCTION ON)
endif ()

if (NOT BUILD_PRODUCTION)

    if (EXISTS "${REVISION_FILE}")
        file(READ "${REVISION_FILE}" GIT_SHORT_SHA)
        string(STRIP "${GIT_SHORT_SHA}" GIT_SHORT_SHA)
    else()
        execute_process(
                COMMAND git rev-parse --short=10 HEAD
                WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
                OUTPUT_VARIABLE GIT_SHORT_SHA
                OUTPUT_STRIP_TRAILING_WHITESPACE
                RESULT_VARIABLE GIT_REV_PARSE_RESULT
        )

        if (NOT GIT_REV_PARSE_RESULT EQUAL 0)
            message(WARNING "Could not get hash. Is this a Git repository?")
            set(GIT_SHORT_SHA "unknown")
        endif()
    endif()

    set(VERSION "${GIT_SHORT_SHA}")
endif ()

message(STATUS "Building StockDory ${VERSION} (${CODENAME})")

include(Information.cmake)

if (BUILD_CI)
    set(BUILD_NATIVE OFF)
    set(BUILD_PGO    OFF)
endif ()

if (BUILD_NATIVE)
    set(ARCHITECTURE "native")
endif ()

if (APPLE)
    if (NOT ARCHITECTURE MATCHES "native")
        set(ARCHITECTURE_FLAGS "-mcpu=${ARCHITECTURE}")
    elseif (ARCHITECTURE)
        set(ARCHITECTURE_FLAGS "-march=native")
    endif ()
elseif (ARCHITECTURE)
    set(ARCHITECTURE_FLAGS "-march=${ARCHITECTURE}")
endif ()

if (ARCHITECTURE_FLAGS)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${ARCHITECTURE_FLAGS}")
endif ()

if (BUILD_PGO)
    if (NOT EXISTS ${CMAKE_BINARY_DIR}/pgo.profdata)
        message(STATUS "PGO: No profile data found, adding profiling steps to the build...")
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fprofile-instr-generate=${CMAKE_BINARY_DIR}/pgo.profraw")
    else ()
        message(STATUS "PGO: Profile data found, using it for optimization...")
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fprofile-use=${CMAKE_BINARY_DIR}/pgo.profdata")
    endif ()
endif ()

include(FetchDependencies.cmake)
include(EmbedFile.cmake)

file(GLOB NNModel "src/Engine/Model/*.nnue")

if (ANDROID)
    if (STOCKDORY_EXPECT_DOTPROD)
        set(STOCKDORY_SIMD "ARM64 NEON + DotProd")
        set(STOCKDORY_DOTPROD_NOTE "MantaRay DotProd VNNI backend selected; SDOT is used for eligible u08*i08 kernels only")
    else ()
        set(STOCKDORY_SIMD "ARM64 NEON")
        set(STOCKDORY_DOTPROD_NOTE "not enabled")
    endif ()

    set(STOCKDORY_NETWORK_METADATA "")
    foreach(_network IN LISTS NNModel)
        get_filename_component(_network_name "${_network}" NAME)
        file(SHA256 "${_network}" _network_sha256)
        string(APPEND STOCKDORY_NETWORK_METADATA "network=${_network_name}\nnetwork_sha256=${_network_sha256}\n")
    endforeach ()

    file(WRITE "${CMAKE_BINARY_DIR}/stockdory-build-metadata.txt"
        "engine=StockDory\nversion=${VERSION}\ncodename=${CODENAME}\nplatform=${CMAKE_SYSTEM_NAME}\nprocessor=${CMAKE_SYSTEM_PROCESSOR}\narchitecture=${ARCHITECTURE}\nsimd=${STOCKDORY_SIMD}\ndotprod_note=${STOCKDORY_DOTPROD_NOTE}\n${STOCKDORY_NETWORK_METADATA}")
endif ()

if (NNModel)
    message(STATUS "Embedding NNUE Model: ${NNModel}")
    EmbedFile(
            ${NNModel}
            ${CMAKE_CURRENT_BINARY_DIR}/BuildSystem/Model/NeuralNetworkBinary.h
            NeuralNetworkBinary
    )
endif ()

file(GLOB_RECURSE HEADER "src/*.h")

add_executable(StockDory src/main.cpp ${HEADER})

if (BUILD_TUNING)
    target_compile_definitions(StockDory PRIVATE BUILD_TUNING)
endif ()

if (ANDROID AND STOCKDORY_EXPECT_DOTPROD)
    target_compile_definitions(StockDory PRIVATE STOCKDORY_EXPECT_DOTPROD=1)
endif ()

target_include_directories(StockDory PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_include_directories(StockDory PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/BuildSystem)

target_include_directories(StockDory PRIVATE ${fastrange_SOURCE_DIR} ${strutil_SOURCE_DIR})

target_link_libraries(StockDory MantaRay)

if (WIN32)
    target_link_libraries(StockDory advapi32)
elseif (NOT ANDROID)
    target_link_libraries(StockDory pthread)
endif ()

if (CMAKE_BUILD_TYPE MATCHES "Release")
    message(STATUS "Flags: ${CMAKE_CXX_FLAGS} | ${CMAKE_CXX_FLAGS_RELEASE}")
elseif (CMAKE_BUILD_TYPE MATCHES "Debug")
    message(STATUS "Flags: ${CMAKE_CXX_FLAGS} | ${CMAKE_CXX_FLAGS_DEBUG}")
else ()
    message(STATUS "Flags: ${CMAKE_CXX_FLAGS}")
endif ()
