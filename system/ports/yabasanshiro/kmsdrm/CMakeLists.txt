project(yabause-kmsdrm)

yab_port_start()

find_package(SDL2 REQUIRED)

add_definitions(-DNO_CLI)

set(PORT_INCLUDE_DIRS ${SDL2_INCLUDE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/..)
set(PORT_LIBRARIES ${SDL2_LIBRARY})

set(yabause_kmsdrm_SOURCES main.cpp)

if(YAB_WANT_VULKAN)
    set(yabause_kmsdrm_SOURCES ${yabause_kmsdrm_SOURCES} Window_kmsdrm.cpp)
    set(PORT_INCLUDE_DIRS ${PORT_INCLUDE_DIRS} ${CMAKE_CURRENT_SOURCE_DIR}/../vulkan)
endif()

add_executable(yabause-kmsdrm ${yabause_kmsdrm_SOURCES})
include_directories(${PORT_INCLUDE_DIRS})
target_link_libraries(yabause-kmsdrm yabause ${YABAUSE_LIBRARIES} ${PORT_LIBRARIES}
    ${LIBCHDR_LIBRARIES} stdc++fs)

if(YAB_WANT_VULKAN)
    target_link_libraries(yabause-kmsdrm ${SHADERC_LIBRARIES} ${LIBVULKAN})
endif()

yab_port_success(yabause-kmsdrm)
install(TARGETS yabause-kmsdrm DESTINATION "bin")
