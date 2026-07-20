%global qt5_snapshot_version 2.52.1

Name:       wpewebkit2-qt5
Summary:    Qt5 QML plugin for WPE WebKit 2.52.5
Version:    2.52.5
Release:    1
License:    LGPLv2+
URL:        https://wpewebkit.org
# Source is the carried-forward Qt5 bridge snapshot from the validated 2.52.1 tree.
Source0:    wpewebkit-qt5-%{qt5_snapshot_version}.tar.xz
Source1:    sfos-toolchain.cmake

BuildRequires:  cmake >= 3.20
BuildRequires:  ninja
BuildRequires:  gcc-c++
BuildRequires:  pkgconfig(Qt5Core)
BuildRequires:  pkgconfig(Qt5Gui)
BuildRequires:  pkgconfig(Qt5Quick)
BuildRequires:  pkgconfig(Qt5Qml)
BuildRequires:  pkgconfig(wpewebkit-2.0)
BuildRequires:  pkgconfig(wpe-1.0)
BuildRequires:  pkgconfig(glib-2.0)

Requires:   wpewebkit2 = %{version}
Requires:   sailfishsilica-qt5

%description
Qt5 QML plugin (org.wpewebkit.qtwpe) for embedding WPE WebKit web views
into Qt Quick / Silica applications on Sailfish OS.

Installs:
  /usr/lib64/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so
  /usr/lib64/qt5/qml/org/wpewebkit/qtwpe/qmldir

Import in QML:
  import org.wpewebkit.qtwpe 1.0

# ===========================================================================
%prep
%setup -q -n wpewebkit-qt5-%{qt5_snapshot_version}

%build
cmake -B build -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=%{SOURCE1} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=%{_prefix} \
    -DCMAKE_INSTALL_LIBDIR=lib
ninja -C build %{?_smp_mflags}

%install
DESTDIR=%{buildroot} cmake --install build --prefix %{_prefix}
install -d %{buildroot}%{_libdir}
ln -sfn /usr/lib64/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so \
    %{buildroot}%{_libdir}/libqtwpe.so

%post
/sbin/ldconfig || :

%postun
/sbin/ldconfig || :

%files
%{_libdir}/libqtwpe.so
%dir %{_libdir}/qt5/qml/org/wpewebkit
%dir %{_libdir}/qt5/qml/org/wpewebkit/qtwpe
%{_libdir}/qt5/qml/org/wpewebkit/qtwpe/libqtwpe.so
%{_libdir}/qt5/qml/org/wpewebkit/qtwpe/qmldir
