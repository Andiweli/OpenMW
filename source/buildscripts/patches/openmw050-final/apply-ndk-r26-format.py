#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: apply-ndk-r26-format.py <openmw-source-dir>')

root = Path(sys.argv[1])
cmake = root / 'CMakeLists.txt'
openmw_cmake = root / 'apps' / 'openmw' / 'CMakeLists.txt'

for path in (cmake, openmw_cmake):
    if not path.is_file():
        raise SystemExit(f'missing expected OpenMW 0.50 source file: {path}')

marker_compile = 'OPENMW_ANDROID_NDK_R26_EXPERIMENTAL_FORMAT'
marker_probe = 'OPENMW_ANDROID_NDK_R26_FORMAT_PROBE'
marker_link = 'OPENMW_ANDROID_NDK_R26_EXPERIMENTAL_FORMAT_LINK'

text = cmake.read_text(encoding='utf-8')
if marker_compile not in text:
    needle = 'set(CMAKE_CXX_EXTENSIONS OFF)\n'
    if text.count(needle) != 1:
        raise SystemExit('could not locate unique CMAKE_CXX_EXTENSIONS anchor in OpenMW 0.50 CMakeLists.txt')
    replacement = needle + r'''
# OPENMW_ANDROID_NDK_R26_EXPERIMENTAL_FORMAT
# Android NDK r26b ships a libc++ 17 snapshot whose <format> implementation is
# still hidden by _LIBCPP_HAS_NO_INCOMPLETE_FORMAT unless the libc++
# experimental-library gate is enabled. OpenMW 0.50 uses std::format in both
# components and game code, so enable that vendor gate for Android C++ files.
if (ANDROID AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    add_compile_options("$<$<COMPILE_LANGUAGE:CXX>:-fexperimental-library>")

    # OPENMW_ANDROID_NDK_R26_FORMAT_PROBE
    # Fail during CMake configuration, before the long OpenMW compile, unless
    # the exact Android toolchain can compile *and link* both the simple and
    # floating-point formatting forms used by OpenMW 0.50.
    include(CheckCXXSourceCompiles)
    set(_openmw_saved_required_flags "${CMAKE_REQUIRED_FLAGS}")
    set(_openmw_saved_required_libraries "${CMAKE_REQUIRED_LIBRARIES}")
    set(CMAKE_REQUIRED_FLAGS "${CMAKE_REQUIRED_FLAGS} -fexperimental-library")
    list(APPEND CMAKE_REQUIRED_LIBRARIES c++experimental)
    check_cxx_source_compiles([=[
        #include <format>
        #include <string>
        int main()
        {
            const std::string a = std::format("value={}", 42);
            const std::string b = std::format("{:.3f}", 1.25f);
            return (a.empty() || b.empty()) ? 1 : 0;
        }
    ]=] OPENMW_ANDROID_NDK_R26_STD_FORMAT_WORKS)
    set(CMAKE_REQUIRED_FLAGS "${_openmw_saved_required_flags}")
    set(CMAKE_REQUIRED_LIBRARIES "${_openmw_saved_required_libraries}")
    unset(_openmw_saved_required_flags)
    unset(_openmw_saved_required_libraries)

    if (NOT OPENMW_ANDROID_NDK_R26_STD_FORMAT_WORKS)
        message(FATAL_ERROR
            "Android NDK r26 std::format probe failed. The toolchain must support "
            "-fexperimental-library and libc++experimental before OpenMW 0.50 can be built.")
    endif()
endif()
'''
    text = text.replace(needle, replacement, 1)
    cmake.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android NDK r26 std::format compile support (-fexperimental-library).')
    print('Installed configure-time std::format compile/link probe.')
else:
    print('Android NDK r26 std::format compile support is already applied.')
    if marker_probe in text:
        print('Android NDK r26 std::format configure-time probe is already applied.')
    else:
        raise SystemExit('format compile marker exists but configure-time probe marker is missing')

text = openmw_cmake.read_text(encoding='utf-8')
if marker_link not in text:
    needle = '    target_link_libraries(openmw openmw-lib)\n'
    if text.count(needle) != 1:
        raise SystemExit('could not locate unique openmw target_link_libraries anchor in OpenMW 0.50 apps/openmw/CMakeLists.txt')
    replacement = needle + r'''

    # OPENMW_ANDROID_NDK_R26_EXPERIMENTAL_FORMAT_LINK
    # The r26b gated format implementation has out-of-line support in
    # libc++experimental.a. Keep the extra library Android-only.
    if (ANDROID)
        target_link_libraries(openmw c++experimental)
    endif()
'''
    text = text.replace(needle, replacement, 1)
    openmw_cmake.write_text(text, encoding='utf-8', newline='\n')
    print('Linked Android OpenMW against libc++experimental for std::format.')
else:
    print('Android libc++experimental std::format link support is already applied.')

# Strict verification: compile gate, configure-time probe and final link support
# are all required. Missing one of them must stop the patch step immediately.
verify_cmake = cmake.read_text(encoding='utf-8')
verify_openmw = openmw_cmake.read_text(encoding='utf-8')
for marker in (marker_compile, marker_probe):
    if marker not in verify_cmake:
        raise SystemExit(f'verification failed: {marker} missing')
if marker_link not in verify_openmw:
    raise SystemExit('verification failed: Android libc++experimental link marker missing')

print('OpenMW 0.50 Android NDK r26 C++20 format compatibility: READY')
