Name:       wpe-sfos-compat
Summary:    SFOS compatibility shims for WPE WebKit
Version:    1.0.0
Release:    1
License:    LGPL-2.1+
URL:        https://github.com/SpecSierra/wpe-sfos-build
# Create with: git archive --prefix=wpe-sfos-compat-1.0.0/ HEAD | bzip2 > wpe-sfos-compat-1.0.0.tar.bz2
# Run from inside the wpe-sfos-build git repo root.
Source0:    %{name}-%{version}.tar.bz2

BuildRequires:  gcc

%description
Compatibility shim libraries historically used to run Atlantic WPE builds on
older Sailfish OS baselines. The current SFOS 5.1 default path keeps this
package explicit and temporary rather than treating it as the normal runtime.

Provides:
  - glibc 2.31+ symbol stubs missing from SFOS glibc 2.30
  - SIGILL skip handler for ARMv8.1+ CPU feature probes
  - EGL stub entry points for libepoxy load-time probing
  - C++ ABI / stdlibc++ compatibility layer

All shims are loaded via Atlantic browser/helper launch wrappers, not via
global nemo session environment injection.

# ---------------------------------------------------------------------------
%package -n wpe-sfos-compat-devel
Summary:    Development headers for wpe-sfos-compat (unused; placeholder)
Requires:   %{name} = %{version}-%{release}
%description -n wpe-sfos-compat-devel
Placeholder devel sub-package.

# ===========================================================================
%prep
%setup -q -n %{name}-%{version}

%build
SYSROOT=%{_prefix}
COMPAT_SRC=shims/compat
CC="gcc"
CFLAGS="-O2 -march=armv8-a -mtune=cortex-a73.cortex-a53 -fPIC -fvisibility=hidden"
SHARED="-shared -Wl,--allow-shlib-undefined"

$CC $CFLAGS $SHARED -o libglibc-compat.so       ${COMPAT_SRC}/libglibc-compat.c
$CC $CFLAGS $SHARED -o libsigill_skip.so         ${COMPAT_SRC}/libsigill_skip.c
$CC $CFLAGS $SHARED -o libegl-stubs.so           ${COMPAT_SRC}/libegl-stubs.c

%install
install -d %{buildroot}%{_libdir}/wpe-compat

for lib in \
    libglibc-compat.so \
    libsigill_skip.so \
    libegl-stubs.so; do
    install -m 755 $lib %{buildroot}%{_libdir}/wpe-compat/$lib
done

%post
/sbin/ldconfig || :

%postun
/sbin/ldconfig || :

%files
%license LICENSE
%dir %{_libdir}/wpe-compat
%{_libdir}/wpe-compat/libglibc-compat.so
%{_libdir}/wpe-compat/libsigill_skip.so
%{_libdir}/wpe-compat/libegl-stubs.so
%{_libdir}/wpe-compat/libsyncskip.so
