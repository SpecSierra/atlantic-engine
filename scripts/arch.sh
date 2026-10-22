# shellcheck shell=bash
#
# The target CPU architecture, sourced by common.sh. Everything that differs
# between the aarch64 build (the default, phones on 64-bit Sailfish OS) and the
# armv7hl one (older phones on 32-bit Sailfish OS) is decided here.
#
# ATL_ARCH picks it; unset, it follows the machine: the armv7hl build runs the
# same scripts inside a 32-bit Ubuntu (armhf) chroot under `setarch linux32`
# (scripts/armv7/ci-build-armv7.sh), where uname -m says armv7l.
#
#   ATL_RPM_ARCH     RPM architecture of the packages
#   ATL_LIBDIR       library directory on the phone and in the SFOS sysroot (/usr/<it>)
#   ATL_MULTIARCH    Ubuntu's multiarch directory for the build machine's libraries
#   ATL_ARCH_FLAGS   CPU flags for the compat shims (stage-compat-shims.sh)
#   ATL_NATIVE_MESON_FILE, ATL_WEBKIT_TOOLCHAIN_GCC, ATL_QT_TOOLCHAIN
#                    per-architecture build files (the aarch64 ones keep their
#                    historical names so their toolchain hashes do not change)

if [ -z "${ATL_ARCH:-}" ]; then
    case "$(uname -m)" in
        armv7l|armv8l|arm) ATL_ARCH=armv7hl ;;
        *) ATL_ARCH=aarch64 ;;
    esac
fi

case "${ATL_ARCH}" in
    aarch64)
        ATL_RPM_ARCH=aarch64
        ATL_LIBDIR=lib64
        ATL_MULTIARCH=aarch64-linux-gnu
        ATL_ARCH_FLAGS="-march=armv8-a -mtune=cortex-a73.cortex-a53"
        ATL_NATIVE_MESON_FILE="${BUILD_TOOLS}/native-meson.ini"
        ATL_WEBKIT_TOOLCHAIN_GCC="${BUILD_TOOLS}/sfos-toolchain-native.cmake"
        ATL_QT_TOOLCHAIN="${BUILD_TOOLS}/sfos-toolchain.cmake"
        ;;
    armv7hl)
        # ARMv7-A, hard float, NEON, Thumb-2 (WebKit's ARMv7 JIT needs Thumb-2).
        # Every phone that runs 32-bit Sailfish OS 5 has NEON.
        ATL_RPM_ARCH=armv7hl
        ATL_LIBDIR=lib
        ATL_MULTIARCH=arm-linux-gnueabihf
        ATL_ARCH_FLAGS="-march=armv7-a -mfpu=neon -mfloat-abi=hard -mthumb"
        ATL_NATIVE_MESON_FILE="${BUILD_TOOLS}/native-meson-armv7hl.ini"
        ATL_WEBKIT_TOOLCHAIN_GCC="${BUILD_TOOLS}/sfos-toolchain-native-armv7hl.cmake"
        ATL_QT_TOOLCHAIN="${BUILD_TOOLS}/sfos-toolchain-armv7hl.cmake"
        ;;
    *)
        echo "ERROR: unknown ATL_ARCH '${ATL_ARCH}' (aarch64 or armv7hl)" >&2
        exit 1
        ;;
esac

export ATL_ARCH ATL_RPM_ARCH ATL_LIBDIR ATL_MULTIARCH ATL_ARCH_FLAGS \
    ATL_NATIVE_MESON_FILE ATL_WEBKIT_TOOLCHAIN_GCC ATL_QT_TOOLCHAIN
