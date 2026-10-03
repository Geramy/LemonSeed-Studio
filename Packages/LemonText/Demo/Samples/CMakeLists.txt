cmake_minimum_required(VERSION 3.28)
project(KernelLab VERSION 0.4.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(KERNEL_LAB_TESTS "Build the test suite" ON)

add_library(kernel_lab
    src/kernel_queue.cpp
    src/ring_buffer.c
)
target_include_directories(kernel_lab PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_options(kernel_lab PRIVATE
    $<$<CXX_COMPILER_ID:Clang>:-Wall -Wextra -Wpedantic>
)

if(CMAKE_SYSTEM_NAME STREQUAL "WASI")
    target_compile_definitions(kernel_lab PRIVATE KERNEL_LAB_WASI=1)
endif()

if(KERNEL_LAB_TESTS)
    enable_testing()
    add_executable(kernel_lab_tests tests/queue_tests.cpp)
    target_link_libraries(kernel_lab_tests PRIVATE kernel_lab)
    add_test(NAME queue COMMAND kernel_lab_tests)
endif()

install(TARGETS kernel_lab DESTINATION lib)
