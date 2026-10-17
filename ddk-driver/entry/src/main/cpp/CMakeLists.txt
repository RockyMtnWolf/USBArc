cmake_minimum_required(VERSION 3.4.1)
project(usbarc_ddk)

set(USBARC_DDK_SOURCE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/ddk/usbarc_ddk.cpp)
add_library(usbarc_ddk SHARED ${USBARC_DDK_SOURCE})
find_library(ACE_NAPI_LIB ace_napi.z)
find_library(USB_DDK_LIB usb_ndk.z)
target_link_libraries(usbarc_ddk PUBLIC ${ACE_NAPI_LIB} ${USB_DDK_LIB})
