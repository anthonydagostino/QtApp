cmake_minimum_required(VERSION 3.16)

project(HeadlessQtApp
    VERSION 1.0.0
    DESCRIPTION "Headless Qt 6.6.0 widgets application for Squish attachment on RHEL 9 x86_64"
    LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# The Squish for Qt 8.1.0 wrapper was built with Qt 6.8.0 and needs the
# Qt_6_PRIVATE_API symbol version from that exact libQt6Core.so.6.
set(HEADLESSQTAPP_REQUIRED_QT_VERSION "6.8.0" CACHE STRING
    "Exact Qt version this application must be built against")
option(HEADLESSQTAPP_ALLOW_QT_VERSION_MISMATCH
    "Allow building against a Qt version other than HEADLESSQTAPP_REQUIRED_QT_VERSION (NOT recommended)" OFF)

# The application itself only needs Core and Gui, but every Qt module shipped in
# libs/lib64 is linked (and kept with --no-as-needed) so that it is mapped at process
# start: Squish's preloaded wrapper then finds every Qt library it may need already
# loaded, without any LD_LIBRARY_PATH.
find_package(Qt6 ${HEADLESSQTAPP_REQUIRED_QT_VERSION} REQUIRED
    COMPONENTS Core Gui Widgets Network Xml Concurrent PrintSupport)
qt_standard_project_setup()

message(STATUS "Qt6Core version: ${Qt6Core_VERSION}")
if(NOT Qt6Core_VERSION VERSION_EQUAL HEADLESSQTAPP_REQUIRED_QT_VERSION)
    if(HEADLESSQTAPP_ALLOW_QT_VERSION_MISMATCH)
        message(WARNING "Building against Qt ${Qt6Core_VERSION}, not ${HEADLESSQTAPP_REQUIRED_QT_VERSION} (mismatch explicitly allowed)")
    else()
        message(FATAL_ERROR
            "Qt ${Qt6Core_VERSION} found, but this application must be built against Qt "
            "${HEADLESSQTAPP_REQUIRED_QT_VERSION} exactly (set CMAKE_PREFIX_PATH to the Qt 6.8.0 gcc_64 SDK).")
    endif()
endif()

# Verify, before building, that the selected libQt6Core.so.6 carries the
# Qt_6_PRIVATE_API symbol version:
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
    message(WARNING "readelf not found; Qt_6_PRIVATE_API check skipped at configure time.")
endif()

qt_add_executable(HeadlessQtApp
    main.cpp)

target_compile_definitions(HeadlessQtApp PRIVATE
    HEADLESSQTAPP_VERSION="${PROJECT_VERSION}"
    QT_NO_CAST_FROM_ASCII
    QT_NO_CAST_TO_ASCII)

target_compile_options(HeadlessQtApp PRIVATE -Wall -Wextra)

target_link_options(HeadlessQtApp PRIVATE
    "LINKER:--no-as-needed"
    # DT_RPATH (not DT_RUNPATH): it is inherited by every library loaded into the
    # process, so Squish's preloaded wrapper and dlopen'ed plugins resolve their Qt
    # dependencies from <pkg>/libs/lib64 as well.
    "LINKER:--disable-new-dtags")
target_link_libraries(HeadlessQtApp PRIVATE
    Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Network Qt6::Xml Qt6::Concurrent Qt6::PrintSupport)

# Relative runtime search path: <pkg>/bin/HeadlessQtApp -> <pkg>/libs/lib64
set_target_properties(HeadlessQtApp PROPERTIES
    INSTALL_RPATH "$ORIGIN/../libs/lib64"
    INSTALL_RPATH_USE_LINK_PATH OFF
    BUILD_WITH_INSTALL_RPATH OFF
    SKIP_BUILD_RPATH OFF)

install(TARGETS HeadlessQtApp RUNTIME DESTINATION bin)
# qt.conf next to the binary makes Qt find <pkg>/plugins and <pkg>/libs/lib64/fonts.
install(FILES tools/packaging/qt.conf DESTINATION bin)
