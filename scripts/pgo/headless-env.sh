#!/bin/bash
# Sourced by train.sh and bench.sh: builds atl-headless against an engine
# prefix and sets the environment that lets that engine run on the build host.
#
#   atl_headless_setup PREFIX WORKDIR
#
# The engine is linked against the SFOS sysroot's ICU 73 (the host has ICU 74),
# so those three libraries are borrowed from the sysroot — and only those: the
# rest of the sysroot's /usr/lib64 must not shadow the host's libraries.

atl_headless_setup() {
    local prefix="$1"
    local workdir="$2"
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local sysroot="${SYSROOT:-/opt/github-runner/cache/sfos-sysroot-5.1.0.11}"
    local lib

    mkdir -p "${workdir}/icu" "${workdir}/xdg" "${workdir}/home"
    chmod 700 "${workdir}/xdg"
    for lib in libicudata libicui18n libicuuc; do
        ln -sf "${sysroot}/usr/lib64/${lib}.so.73" "${workdir}/icu/"
    done

    # shellcheck disable=SC2046
    gcc -O2 -o "${workdir}/atl-headless" "${here}/atl-headless.c" \
        $(PKG_CONFIG_PATH="${prefix}/lib/pkgconfig" pkg-config --cflags --libs \
            wpe-webkit-2.0 wpebackend-fdo-1.0 glib-2.0 libsoup-3.0) \
        -Wl,--allow-shlib-undefined

    # See host-condvar-shim.c: the host's glibc loses condition-variable
    # wake-ups under this engine, which hangs sessions mid-workload.
    gcc -O2 -fPIC -shared -o "${workdir}/host-condvar-shim.so" "${here}/host-condvar-shim.c"
    ATL_HEADLESS_PRELOAD="${workdir}/host-condvar-shim.so"

    ATL_HEADLESS="${workdir}/atl-headless"
    ATL_HEADLESS_ICU_DIR="${workdir}/icu"
    export HOME="${workdir}/home"
    export XDG_RUNTIME_DIR="${workdir}/xdg"
    export XDG_CACHE_HOME="${workdir}/home/.cache"
    export XDG_DATA_HOME="${workdir}/home/.local/share"
    # No GPU on the build host: Mesa's software rasteriser stands in for it.
    export LIBGL_ALWAYS_SOFTWARE=1
    # bubblewrap needs namespaces the CI user may not have, and is not what is
    # being measured.
    export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
}

# Run a workload with:
#   LD_PRELOAD="${ATL_HEADLESS_PRELOAD}" LD_LIBRARY_PATH="${prefix}/lib:${ATL_HEADLESS_ICU_DIR}" \
#       "${ATL_HEADLESS}" WORKLOAD
# The helper processes are started from the path baked into that engine, so
# the prefix has to be where the engine was installed, not a copy of it.

# Wait for the engine's helper processes to leave by themselves (an
# instrumented one writes its profile on the way out), then stop stragglers.
atl_headless_wait_helpers() {
    local prefix="$1"
    local waited=0
    while pgrep -f "^${prefix}/libexec/wpe-webkit-2.0/WPE" >/dev/null 2>&1; do
        if [ "${waited}" -ge 120 ]; then
            echo "  helper processes still alive after ${waited} s, terminating them" >&2
            pkill -TERM -f "^${prefix}/libexec/wpe-webkit-2.0/WPE" || true
            sleep 5
            pkill -KILL -f "^${prefix}/libexec/wpe-webkit-2.0/WPE" || true
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
}
