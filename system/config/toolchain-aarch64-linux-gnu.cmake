# MIMIKI CMake Toolchain File for aarch64-linux-gnu Cross Compilation

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CROSS_COMPILE "aarch64-linux-gnu-")
set(CMAKE_C_COMPILER ${CROSS_COMPILE}gcc)
set(CMAKE_CXX_COMPILER ${CROSS_COMPILE}g++)
set(CMAKE_ASM_COMPILER ${CROSS_COMPILE}as)
set(CMAKE_AR ${CROSS_COMPILE}ar CACHE FILEPATH "Archiver")
set(CMAKE_RANLIB ${CROSS_COMPILE}ranlib CACHE FILEPATH "Ranlib")
set(CMAKE_STRIP ${CROSS_COMPILE}strip CACHE FILEPATH "Strip")
set(CMAKE_NM ${CROSS_COMPILE}nm CACHE FILEPATH "NM")
set(CMAKE_OBJCOPY ${CROSS_COMPILE}objcopy CACHE FILEPATH "Objcopy")
set(CMAKE_OBJDUMP ${CROSS_COMPILE}objdump CACHE FILEPATH "Objdump")

set(CMAKE_FIND_ROOT_PATH
    /usr/aarch64-linux-gnu
    /usr/lib/aarch64-linux-gnu
)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# SDL2 installation path from build system
# This can be overridden via -DSDL2_INSTALL=<path>
if(NOT DEFINED SDL2_INSTALL)
    get_filename_component(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
    set(SDL2_INSTALL "${REPO_ROOT}/build/sdl2-install" CACHE PATH "SDL2 installation path")
endif()

if(EXISTS "${SDL2_INSTALL}/usr/lib/pkgconfig")
    set(ENV{PKG_CONFIG_PATH} "${SDL2_INSTALL}/usr/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
    set(ENV{PKG_CONFIG_SYSROOT_DIR} "${SDL2_INSTALL}")
    set(ENV{PKG_CONFIG_LIBDIR} "/usr/lib/aarch64-linux-gnu/pkgconfig")
    find_program(PKG_CONFIG_EXECUTABLE NAMES ${CROSS_COMPILE}pkg-config pkg-config)
    if(PKG_CONFIG_EXECUTABLE)
        set(PKG_CONFIG_EXECUTABLE ${PKG_CONFIG_EXECUTABLE} CACHE FILEPATH "pkg-config executable")
    endif()
endif()

set(CMAKE_C_FLAGS_RELEASE "-Ofast -DNDEBUG -flto=auto" CACHE STRING "C Release flags")
set(CMAKE_CXX_FLAGS_RELEASE "-Ofast -DNDEBUG -flto=auto" CACHE STRING "C++ Release flags")
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -march=armv8-a" CACHE STRING "C flags")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=armv8-a" CACHE STRING "C++ flags")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -flto=auto" CACHE STRING "Executable linker flags")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -flto=auto" CACHE STRING "Shared linker flags")

if(EXISTS "${SDL2_INSTALL}/usr/lib/cmake/SDL2")
    list(APPEND CMAKE_PREFIX_PATH "${SDL2_INSTALL}/usr/lib/cmake/SDL2")
    list(APPEND CMAKE_PREFIX_PATH "${SDL2_INSTALL}/usr")
endif()

if(EXISTS "${SDL2_INSTALL}/usr/bin/sdl2-config")
    set(SDL2_CONFIG "${SDL2_INSTALL}/usr/bin/sdl2-config" CACHE FILEPATH "SDL2 config script")
endif()

set(CMAKE_CROSSCOMPILING TRUE)

