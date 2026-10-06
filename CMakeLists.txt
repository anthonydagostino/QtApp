cmake_minimum_required(VERSION 3.16)

project(squish-anchor
    VERSION 1.0.0
    DESCRIPTION "Headless Qt anchor process for Squish attachment (RHEL 9 x86_64)"
    LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# The Squish Qt wrapper this process anchors was built with Qt 6.6.0 and needs
# the Qt_6_PRIVATE_API symbol version from that exact libQt6Core.so.6.
set(SQUISH_ANCHOR_REQUIRED_QT_VERSION "6.6.0" CACHE STRING
    "Exact Qt version this application must be built against")
option(SQUISH_ANCHOR_ALLOW_QT_VERSION_MISMATCH
    "Allow building against a Qt version other than SQUISH_ANCHOR_REQUIRED_QT_VERSION (NOT recommended)" OFF)

# Only Qt Core. No Gui/Widgets/Quick/Qml/DBus/Network.
find_package(Qt6 ${SQUISH_ANCHOR_REQUIRED_QT_VERSION} REQUIRED COMPONENTS Core)
qt_standard_project_setup()

message(STATUS "Qt6Core version: ${Qt6Core_VERSION}")
if(NOT Qt6Core_VERSION VERSION_EQUAL SQUISH_ANCHOR_REQUIRED_QT_VERSION)
    if(SQUISH_ANCHOR_ALLOW_QT_VERSION_MISMATCH)
        message(WARNING "Building against Qt ${Qt6Core_VERSION}, not ${SQUISH_ANCHOR_REQUIRED_QT_VERSION} (mismatch explicitly allowed)")
    else()
        message(FATAL_ERROR
            "Qt ${Qt6Core_VERSION} found, but this application must be built against Qt "
            "${SQUISH_ANCHOR_REQUIRED_QT_VERSION} exactly (set CMAKE_PREFIX_PATH to the Qt 6.6.0 gcc_64 SDK).")
    endif()
endif()

# Verify, before building, that the selected libQt6Core.so.6 carries the
# Qt_6_PRIVATE_API symbol version. Mirrors:
#   readelf --version-info "$QT_ROOT/lib/libQt6Core.so.6" | grep Qt_6_PRIVATE_API
get_target_property(_qt6core_lib Qt6::Core IMPORTED_LOCATION_RELEASE)
if(NOT _qt6core_lib)
    get_target_property(_qt6core_lib Qt6::Core IMPORTED_LOCATION)
endif()
message(STATUS "Qt6Core library: ${_qt6core_lib}")
find_program(READELF_EXECUTABLE NAMES readelf)
if(READELF_EXECUTABLE AND _qt6core_lib AND EXISTS "${_qt6core_lib}")
    execute_process(
        COMMAND "${READELF_EXECUTABLE}" --version-info "${_qt6core_lib}"
        OUTPUT_VARIABLE _qt6core_version_info
        ERROR_QUIET
        RESULT_VARIABLE _readelf_rc)
    if(NOT _readelf_rc EQUAL 0)
        message(FATAL_ERROR "readelf --version-info failed on ${_qt6core_lib}")
    endif()
    if(_qt6core_version_info MATCHES "Qt_6_PRIVATE_API")
        message(STATUS "Qt_6_PRIVATE_API symbol version: present in ${_qt6core_lib}")
    else()
        message(FATAL_ERROR
            "The selected Qt Core library (${_qt6core_lib}) does not export the "
            "Qt_6_PRIVATE_API symbol version. The supplied Qt SDK is incompatible with the "
            "installed Squish Qt wrapper. Refusing to build against it.")
    endif()
else()
    message(WARNING "readelf not found; Qt_6_PRIVATE_API check skipped at configure time "
                    "(scripts/verify-qt-sdk.sh performs the same check).")
endif()

qt_add_executable(squish-anchor
    src/main.cpp)

target_compile_definitions(squish-anchor PRIVATE
    SQUISH_ANCHOR_VERSION="${PROJECT_VERSION}"
    QT_NO_CAST_FROM_ASCII
    QT_NO_CAST_TO_ASCII)

target_compile_options(squish-anchor PRIVATE -Wall -Wextra)

target_link_libraries(squish-anchor PRIVATE Qt6::Core)

# Relative runtime search path: <pkg>/bin/squish-anchor -> <pkg>/lib
# Emitted as DT_RUNPATH (--enable-new-dtags). package-runtime.sh verifies this
# and uses patchelf only if the value is not already correct.
set_target_properties(squish-anchor PROPERTIES
    INSTALL_RPATH "$ORIGIN/../lib"
    INSTALL_RPATH_USE_LINK_PATH OFF
    BUILD_WITH_INSTALL_RPATH OFF
    SKIP_BUILD_RPATH OFF)
target_link_options(squish-anchor PRIVATE "LINKER:--enable-new-dtags")

include(GNUInstallDirs)
install(TARGETS squish-anchor
    RUNTIME DESTINATION bin)
