cmake_minimum_required(VERSION 3.4.1)
project(usbip_native)

add_library(usbip_native SHARED usbip_native.cpp)
target_include_directories(usbip_native PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
find_library(ACE_NAPI_LIB ace_napi.z)
target_link_libraries(usbip_native PUBLIC ${ACE_NAPI_LIB})

add_library(usbarc_ddk SHARED ../../../../native/ddk/usbarc_ddk.cpp)
target_include_directories(usbarc_ddk PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
find_library(USB_NDK_LIB usb_ndk.z)
target_link_libraries(usbarc_ddk PUBLIC ${ACE_NAPI_LIB} ${USB_NDK_LIB})
