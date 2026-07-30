Name:       wpewebkit2
Summary:    WPE WebKit 2.52.5 for Sailfish OS
Version:    2.52.5
Release:    1
License:    LGPLv2+ and BSD and MPLv2.0
URL:        https://wpewebkit.org
# Download from: https://wpewebkit.org/releases/wpewebkit-2.52.5.tar.xz
Source0:    wpewebkit-%{version}.tar.xz
Source1:    sfos-toolchain.cmake
Source2:    webkit-portability-webcore.patch
Source3:    patch-glibc-versions.py
Source4:    webkit-build-cmake-fixes.patch
Source5:    webkit-gst-media.patch
Source8:    atlantic-wpe-features.cmake
Source9:    write-webkit-feature-flags.py

BuildRequires:  cmake >= 3.20
BuildRequires:  ninja
BuildRequires:  gcc-c++
BuildRequires:  python3
BuildRequires:  perl
BuildRequires:  gperf
BuildRequires:  ruby
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(gobject-2.0)
BuildRequires:  pkgconfig(libsoup-3.0)
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(fontconfig)
BuildRequires:  pkgconfig(freetype2)
BuildRequires:  pkgconfig(harfbuzz)
BuildRequires:  pkgconfig(icu-uc)
BuildRequires:  pkgconfig(libjpeg)
BuildRequires:  pkgconfig(libpng)
BuildRequires:  pkgconfig(libwebp)
BuildRequires:  pkgconfig(sqlite3)
BuildRequires:  pkgconfig(zlib)
BuildRequires:  pkgconfig(gstreamer-1.0)
BuildRequires:  pkgconfig(gstreamer-app-1.0)
BuildRequires:  pkgconfig(gstreamer-video-1.0)
BuildRequires:  pkgconfig(gstreamer-audio-1.0)
BuildRequires:  pkgconfig(gstreamer-pbutils-1.0)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(libwpe-1.0)
BuildRequires:  pkgconfig(wpebackend-fdo-1.0)
BuildRequires:  pkgconfig(epoxy)

# Runtime: WPE subprocesses are exec'd by the main process
Requires:       wpe-sfos-compat

%description
WPE WebKit 2.52.5 built for Sailfish OS 5.1 aarch64 (Snapdragon 665,
ARMv8.0-A). This is the engine used by the WPE Sailfish Browser as a
replacement for the Gecko/EmbedLite engine.

Build configuration:
  - VIDEO, MEDIA_STREAM, WEB_AUDIO enabled via GStreamer
  - WEB_CODECS disabled
  - GEOLOCATION, SPEECH_SYNTHESIS, XSLT, WEBDRIVER disabled
  - Static libstdc++ / libgcc (no GLIBCXX version requirements)
  - glibc version tags downgraded to GLIBC_2.17

%package devel
Summary:    Development files for WPE WebKit 2.52.5
Requires:   %{name} = %{version}-%{release}

%description devel
Headers and pkg-config files for building against WPE WebKit 2.52.5
on Sailfish OS.

# ===========================================================================
%prep
%setup -q -n wpewebkit-%{version}
# NOTE: this sfdk/rpmbuild path applies only a subset of the stack; the real
# build is the CI native one, which applies all of scripts/patches.sh. These
# three are the consolidated patches that cover what the subset used to be
# (WebCore portability incl. the isnan/Quirks fixes, the CMake repairs, and the
# GStreamer integration).
patch -p1 < %{SOURCE2}
patch -p1 < %{SOURCE4}
patch -p1 < %{SOURCE5}

%build
cmake -B WebKitBuild/Release -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=%{SOURCE1} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=%{_prefix} \
    -C %{SOURCE8} \
    -DPORT=WPE \
    -DENABLE_MINIBROWSER=OFF \
    -DUSE_SKIA=ON \
    -DUSE_SYSPROF_CAPTURE=ON

ninja -C WebKitBuild/Release %{?_smp_mflags}

%install
DESTDIR=%{buildroot} cmake --install WebKitBuild/Release --prefix %{_prefix}

# The injected bundle and generated pkg-config files still need manual staging.
install -d %{buildroot}%{_libdir}/wpe-webkit-2.0/injected-bundle
install -m 755 WebKitBuild/Release/lib/libWPEInjectedBundle.so \
    %{buildroot}%{_libdir}/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so
install -d %{buildroot}%{_libdir}/pkgconfig
install -m 644 WebKitBuild/Release/wpe-webkit-2.0.pc \
    %{buildroot}%{_libdir}/pkgconfig/wpe-webkit-2.0.pc
install -m 644 WebKitBuild/Release/wpe-web-process-extension-2.0.pc \
    %{buildroot}%{_libdir}/pkgconfig/wpe-web-process-extension-2.0.pc

# Preserve the generated build config so packaged installs can be inspected later.
install -d %{buildroot}%{_datadir}/wpe-webkit-2.0/build-config
install -m 644 WebKitBuild/Release/CMakeCache.txt \
    %{buildroot}%{_datadir}/wpe-webkit-2.0/build-config/CMakeCache.txt
install -m 644 WebKitBuild/Release/cmakeconfig.h \
    %{buildroot}%{_datadir}/wpe-webkit-2.0/build-config/cmakeconfig.h
python3 %{SOURCE9} \
    WebKitBuild/Release/CMakeCache.txt \
    %{buildroot}%{_datadir}/wpe-webkit-2.0/build-config/feature-flags.txt \
    %{version} \
    --build-dir WebKitBuild/Release

# Patch GLIBC_2.34+ version tags down to GLIBC_2.17 in all installed binaries
python3 %{SOURCE3} \
    %{buildroot}%{_libdir}/libWPEWebKit-2.0.so.*.*.* \
    %{buildroot}%{_libdir}/wpe-webkit-2.0/libWPEInjectedBundle.so \
    %{buildroot}%{_libexecdir}/wpe-webkit-2.0/WPEWebProcess \
    %{buildroot}%{_libexecdir}/wpe-webkit-2.0/WPENetworkProcess \
    %{buildroot}%{_libexecdir}/wpe-webkit-2.0/WPEGPUProcess

%post
/sbin/ldconfig || :

%postun
/sbin/ldconfig || :

%files
%license Source/WebKit/LICENSE
%{_libdir}/libWPEWebKit-2.0.so.*
%dir %{_libdir}/wpe-webkit-2.0
%dir %{_libdir}/wpe-webkit-2.0/injected-bundle
%{_libdir}/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so
%dir %{_libexecdir}/wpe-webkit-2.0
%{_libexecdir}/wpe-webkit-2.0/WPEWebProcess
%{_libexecdir}/wpe-webkit-2.0/WPENetworkProcess
%{_libexecdir}/wpe-webkit-2.0/WPEGPUProcess
%dir %{_datadir}/wpe-webkit-2.0
%dir %{_datadir}/wpe-webkit-2.0/build-config
%{_datadir}/wpe-webkit-2.0/build-config/CMakeCache.txt
%{_datadir}/wpe-webkit-2.0/build-config/cmakeconfig.h
%{_datadir}/wpe-webkit-2.0/build-config/feature-flags.txt

%files devel
%{_libdir}/libWPEWebKit-2.0.so
%{_includedir}/wpe-webkit-2.0
%{_libdir}/pkgconfig/wpe-webkit-2.0.pc
%{_libdir}/pkgconfig/wpe-web-process-extension-2.0.pc
