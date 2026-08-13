# Clang cross toolchain for aarch64.
# Needed by ARMSX2: its ARM64 JIT requires __attribute__((preserve_most)),
# a clang-only calling convention (pcsx2/vtlb.h hard-errors under GCC).
# Uses the gcc-cross multiarch sysroot that the GCC toolchain file relies on.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(TRIPLE "aarch64-linux-gnu")

set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_COMPILER_TARGET ${TRIPLE})
set(CMAKE_CXX_COMPILER_TARGET ${TRIPLE})
set(CMAKE_ASM_COMPILER clang)
set(CMAKE_ASM_COMPILER_TARGET ${TRIPLE})

# Ubuntu ships only version-suffixed LLVM binutils
find_program(MIROKI_LLVM_AR NAMES llvm-ar llvm-ar-18 llvm-ar-19 llvm-ar-17 REQUIRED)
find_program(MIROKI_LLVM_RANLIB NAMES llvm-ranlib llvm-ranlib-18 llvm-ranlib-19 llvm-ranlib-17 REQUIRED)
find_program(MIROKI_LLVM_STRIP NAMES llvm-strip llvm-strip-18 llvm-strip-19 llvm-strip-17 REQUIRED)
set(CMAKE_AR      ${MIROKI_LLVM_AR} CACHE FILEPATH "Archiver")
set(CMAKE_RANLIB  ${MIROKI_LLVM_RANLIB} CACHE FILEPATH "Ranlib")
set(CMAKE_STRIP   ${MIROKI_LLVM_STRIP} CACHE FILEPATH "Strip")

set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")

list(APPEND CMAKE_FIND_ROOT_PATH /usr/lib/aarch64-linux-gnu)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG" CACHE STRING "C Release flags")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG" CACHE STRING "C++ Release flags")
# clang has no big.LITTLE dotted -mcpu names; tune for the big cluster, which
# carries the JIT/render threads (ARMSX2 is this toolchain's only user).
# The explicit -march both pins v8.2 and satisfies ARMSX2's BuildParameters
# guard, which appends a downgrading -march=armv8.1-a when none is present.
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -mcpu=cortex-a75 -march=armv8.2-a+dotprod" CACHE STRING "C flags")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -mcpu=cortex-a75 -march=armv8.2-a+dotprod" CACHE STRING "C++ flags")
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CMAKE_CROSSCOMPILING TRUE)
