# Native cmake toolchain for WPEWebKit on armv7hl: the 32-bit counterpart of
# sfos-toolchain-native.cmake, used inside the armhf Ubuntu chroot that
# scripts/armv7/ci-build-armv7.sh runs the build in. Like the aarch64 file it
# compiles against the build machine's (Ubuntu armhf) libraries, not the SFOS
# sysroot.
set(CMAKE_SYSTEM_NAME  Linux)
set(CMAKE_SYSTEM_PROCESSOR armv7l)
set(CMAKE_STAGING_PREFIX /opt/wpe-sfos)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# ARMv7-A, hard float, NEON, Thumb-2: WebKit enables its ARMv7 JIT only when the
# compiler targets Thumb-2 (ARM_THUMB2_DETECTED in WebKitFeatures.cmake).
#
# A 32-bit compiler and linker get 4 GB of address space each, which the big
# WebCore objects and the libWPEWebKit link come close to: -g0 keeps debug info
# out whatever the build type says, and --no-keep-memory makes ld trade time for
# memory (what Debian does for its 32-bit WebKit builds).
set(_ATL_ARMV7_FLAGS "-march=armv7-a -mfpu=neon -mfloat-abi=hard -mthumb -fno-semantic-interposition -ffunction-sections -fdata-sections -g0 -I/usr/include/gio-unix-2.0")
set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS}   ${_ATL_ARMV7_FLAGS}")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${_ATL_ARMV7_FLAGS}")

# GCC LTO stays off, as on aarch64 (it dead-strips symbols only the LLInt
# assembly calls).
set(CMAKE_AR     "gcc-ar")
set(CMAKE_NM     "gcc-nm")
set(CMAKE_RANLIB "gcc-ranlib")

set(_ATL_SYSROOT "$ENV{SYSROOT}")
if(_ATL_SYSROOT STREQUAL "")
    set(_ATL_SYSROOT /opt/sfos-sysroot)
endif()
set(STATIC_RUNTIME_FLAGS "-static-libstdc++ -static-libgcc -Wl,--allow-shlib-undefined -Wl,-rpath-link=${_ATL_SYSROOT}/usr/lib")
set(GC_SECTIONS_FLAGS "-Wl,--gc-sections -Wl,-O1 -Wl,--no-keep-memory")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${STATIC_RUNTIME_FLAGS} ${GC_SECTIONS_FLAGS}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${STATIC_RUNTIME_FLAGS} ${GC_SECTIONS_FLAGS}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${STATIC_RUNTIME_FLAGS} ${GC_SECTIONS_FLAGS}")
set(CMAKE_EXE_LINKER_FLAGS    "${CMAKE_EXE_LINKER_FLAGS}    ${STATIC_RUNTIME_FLAGS} ${GC_SECTIONS_FLAGS}")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${STATIC_RUNTIME_FLAGS} ${GC_SECTIONS_FLAGS}")
set(CMAKE_MODULE_LINKER_FLAGS "${CMAKE_MODULE_LINKER_FLAGS} ${STATIC_RUNTIME_FLAGS} ${GC_SECTIONS_FLAGS}")

add_compile_definitions(U_DISABLE_RENAMING=1)
