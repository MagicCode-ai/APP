cmake_minimum_required(VERSION 3.22.1)
project("magic_sr_jni")

if(NOT DEFINED MAGIC_SR_ROOT OR NOT DEFINED MC_STREAMING_ROOT)
    message(FATAL_ERROR "MAGIC_SR_ROOT and MC_STREAMING_ROOT must be set")
endif()

set(MAGIC_LIB_PATH "${MAGIC_SR_ROOT}/lib/android/libmagic_sr.a")
if(NOT EXISTS "${MAGIC_LIB_PATH}")
    message(FATAL_ERROR "Missing MagicSR library: ${MAGIC_LIB_PATH}")
endif()

add_library(magic_sr STATIC IMPORTED)
set_target_properties(magic_sr PROPERTIES IMPORTED_LOCATION ${MAGIC_LIB_PATH})

set(MAGIC_STREAMING_LIB "${MC_STREAMING_ROOT}/lib/android/arm64-v8a/libmc_streaming.a")
if(NOT EXISTS "${MAGIC_STREAMING_LIB}")
    message(FATAL_ERROR "Missing mc_streaming library: ${MAGIC_STREAMING_LIB}")
endif()
add_library(magic_streaming STATIC IMPORTED)
set_target_properties(magic_streaming PROPERTIES IMPORTED_LOCATION ${MAGIC_STREAMING_LIB})

add_library(magic_sr_jni SHARED magic_sr_jni.cpp magic_streaming_jni.cpp)
target_include_directories(magic_sr_jni PRIVATE
    ${MAGIC_SR_ROOT}/interface
    ${MC_STREAMING_ROOT}/include
)

find_library(log-lib log)
find_library(dl-lib dl)
find_library(gles-lib GLESv3)
find_library(egl-lib EGL)
find_library(vulkan-lib vulkan)

target_link_libraries(magic_sr_jni
    magic_sr
    magic_streaming
    ${gles-lib}
    ${egl-lib}
    ${vulkan-lib}
    ${log-lib}
    ${dl-lib}
    z
    m
    android
    -Wl,-Bsymbolic
)
