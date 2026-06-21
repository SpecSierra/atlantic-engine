cmake_minimum_required(VERSION 3.18)
project(qtwpe LANGUAGES CXX)

include(GNUInstallDirs)

find_package(Qt5 REQUIRED COMPONENTS Core Quick Gui)
find_package(Qt5Test)
find_package(PkgConfig REQUIRED)
pkg_check_modules(Epoxy REQUIRED IMPORTED_TARGET epoxy)
pkg_check_modules(WPEWebKit REQUIRED IMPORTED_TARGET wpe-webkit-2.0)
pkg_check_modules(WPEBackendFDO REQUIRED IMPORTED_TARGET wpebackend-fdo-1.0>=1.5.0)
# Direct-composite path (WPEWaylandSubsurface): render web content to a
# wl_subsurface presented directly by the compositor. The SFOS SDK sysroot ships
# libwayland .so's but not the client dev headers (apps use Qt's wayland
# abstraction), so the headers are vendored under wayland-headers/ and the
# libwayland-client / libwayland-egl symbols are resolved at runtime
# (--allow-shlib-undefined; the libs are already loaded by Qt's wayland platform
# plugin). EGL/GLESv2 dev files ARE in the sysroot.
pkg_check_modules(EGL REQUIRED IMPORTED_TARGET egl)
pkg_check_modules(GLESv2 REQUIRED IMPORTED_TARGET glesv2)

add_library(qtwpe MODULE
    WPEQtViewBackend.cpp
    WPEQmlExtensionPlugin.cpp
    WPEQtView.cpp
    WPEQtViewLoadRequest.cpp
    WPEWaylandSubsurface.cpp
    WPEChromeOverlay.cpp
)
set_target_properties(qtwpe PROPERTIES
    OUTPUT_NAME qtwpe
    AUTOMOC ON
)
target_compile_definitions(qtwpe PUBLIC
    QT_NO_KEYWORDS=1
)
target_link_libraries(qtwpe PRIVATE
    PkgConfig::Epoxy
    PkgConfig::WPEWebKit
    PkgConfig::WPEBackendFDO
    PkgConfig::EGL
    PkgConfig::GLESv2
    Qt5::Core
    Qt5::Quick
    Qt5::Gui
)
target_include_directories(qtwpe PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/wayland-headers
    ${Qt5Gui_PRIVATE_INCLUDE_DIRS}
    # config.h shim: WebKitBuild/Release contains cmakeconfig.h symlinked as config.h
    # Required for standalone build (set WPE_WEBKIT_BUILD_DIR if path differs)
    ${WPE_WEBKIT_BUILD_DIR}
)

install(
    TARGETS
        qtwpe
    DESTINATION
        "${CMAKE_INSTALL_LIBDIR}/qt5/qml/org/wpewebkit/qtwpe/"
    COMPONENT
        runtime
)
install(
    FILES
        qmldir
    DESTINATION
        "${CMAKE_INSTALL_LIBDIR}/qt5/qml/org/wpewebkit/qtwpe/"
    COMPONENT
        runtime
)
install(
    FILES
        WPEQtView.h
        WPEQtViewLoadRequest.h
    DESTINATION
        include/wpe-webkit-1.0/wpe/qt
    COMPONENT
        development
)
