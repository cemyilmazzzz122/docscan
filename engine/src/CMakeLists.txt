# DocScan engine (C++17, OpenCV).
#
# Android: built by Gradle through the Flutter plugin, linking OpenCV's static Android SDK.
# Desktop: cmake -S engine/src -B build -DOpenCV_DIR=<opencv>/lib/cmake/opencv5 -DDOCSCAN_CLI=ON
cmake_minimum_required(VERSION 3.10)

project(docscan_engine VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(DOCSCAN_CLI "Build the docscan-cli command line tool" OFF)

if (ANDROID)
  # Static OpenCV Android SDK, downloaded by scripts/fetch_opencv.sh
  if (NOT DEFINED OpenCV_DIR)
    set(OpenCV_DIR "${CMAKE_CURRENT_LIST_DIR}/../third_party/OpenCV-android-sdk/sdk/native/jni")
  endif()
  set(OpenCV_STATIC ON)
endif()

find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs photo OPTIONAL_COMPONENTS geometry)

set(ENGINE_SOURCES scanner.cpp dewarp.cpp api.cpp)

add_library(docscan_engine SHARED ${ENGINE_SOURCES})
target_include_directories(docscan_engine PUBLIC "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(docscan_engine PRIVATE ${OpenCV_LIBS})
set_target_properties(docscan_engine PROPERTIES
  OUTPUT_NAME "docscan_engine"
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)

if (ANDROID)
  # Android 15+ 16 KB page size, and drop unused code from the static OpenCV libraries
  target_link_options(docscan_engine PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--gc-sections" "-Wl,--exclude-libs,ALL")
  target_link_libraries(docscan_engine PRIVATE log)
endif()

if (DOCSCAN_CLI)
  add_executable(docscan-cli "${CMAKE_CURRENT_LIST_DIR}/../cli/main.cpp")
  target_link_libraries(docscan-cli PRIVATE docscan_engine)
  set_target_properties(docscan-cli PROPERTIES BUILD_RPATH "$<TARGET_FILE_DIR:docscan_engine>")
endif()
