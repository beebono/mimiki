set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(TRIPLE "aarch64-linux-gnu")

set(CMAKE_C_COMPILER ${TRIPLE}-gcc)
set(CMAKE_CXX_COMPILER ${TRIPLE}-g++)
set(CMAKE_ASM_COMPILER ${TRIPLE}-as)

set(CMAKE_AR      ${TRIPLE}-ar CACHE FILEPATH "Archiver")
set(CMAKE_RANLIB  ${TRIPLE}-ranlib CACHE FILEPATH "Ranlib")
set(CMAKE_STRIP   ${TRIPLE}-strip CACHE FILEPATH "Strip")
set(CMAKE_NM      ${TRIPLE}-nm CACHE FILEPATH "NM")
set(CMAKE_OBJCOPY ${TRIPLE}-objcopy CACHE FILEPATH "Objcopy")
set(CMAKE_OBJDUMP ${TRIPLE}-objdump CACHE FILEPATH "Objdump")

list(APPEND CMAKE_FIND_ROOT_PATH /usr/lib/aarch64-linux-gnu)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# SDL2 installation path from build system
if(NOT DEFINED SDL2_INSTALL)
    get_filename_component(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
    set(SDL2_INSTALL "${REPO_ROOT}/build/sdl2-install" CACHE PATH "SDL2 installation path")
endif()

if(EXISTS "${SDL2_INSTALL}/usr/lib/pkgconfig")
    set(ENV{PKG_CONFIG_PATH} "${SDL2_INSTALL}/usr/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
    set(ENV{PKG_CONFIG_LIBDIR} "/usr/lib/aarch64-linux-gnu/pkgconfig")
    find_program(PKG_CONFIG_EXECUTABLE NAMES ${TRIPLE}-pkg-config pkg-config)
    if(PKG_CONFIG_EXECUTABLE)
        set(PKG_CONFIG_EXECUTABLE ${PKG_CONFIG_EXECUTABLE} CACHE FILEPATH "pkg-config executable")
    endif()
endif()

if(EXISTS "${SDL2_INSTALL}/usr/lib/cmake/SDL2")
    list(APPEND CMAKE_PREFIX_PATH "${SDL2_INSTALL}/usr/lib/cmake/SDL2")
    list(APPEND CMAKE_PREFIX_PATH "${SDL2_INSTALL}/usr")
    set(SDL2_DIR "${SDL2_INSTALL}/usr/lib/cmake/SDL2")
endif()

if(EXISTS "${SDL2_INSTALL}/usr/bin/sdl2-config")
    set(SDL2_CONFIG "${SDL2_INSTALL}/usr/bin/sdl2-config" CACHE FILEPATH "SDL2 config script")
endif()

# -O3 without -ffast-math: emulators emulate IEEE-754 hardware; fast-math's
# NaN/denormal shortcuts cause real emulation bugs.
set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG -flto=auto" CACHE STRING "C Release flags")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG -flto=auto" CACHE STRING "C++ Release flags")
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# T618: v8.2 (inline LSE atomics) + balanced big.LITTLE scheduling for A75/A55
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -mcpu=cortex-a75.cortex-a55" CACHE STRING "C flags")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -mcpu=cortex-a75.cortex-a55" CACHE STRING "C++ flags")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -flto=auto" CACHE STRING "Executable linker flags")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -flto=auto" CACHE STRING "Shared linker flags")

set(CMAKE_CROSSCOMPILING TRUE)
