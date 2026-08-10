# OpenMW Android v13.13
#
# Bridge the CaveBros ndk-build SDL installation to OpenMW 0.49 Final's
# SDL2::SDL2 CMake target.
#
# CaveBros historically installs SDL headers by copying <SOURCE_DIR>/include
# into ${prefix}. Depending on the exact SDL packaging/layout this can yield
# either:
#
#   ${prefix}/include/SDL.h
#
# or:
#
#   ${prefix}/include/SDL2/SDL.h
#
# Do not hard-code one layout. Resolve the actual installed header root.

get_filename_component(_OPENMW_ANDROID_SDL2_PREFIX
    "${CMAKE_CURRENT_LIST_DIR}/../../.."
    ABSOLUTE
)

set(_OPENMW_ANDROID_SDL2_LIBRARY
    "${_OPENMW_ANDROID_SDL2_PREFIX}/lib/libSDL2.so"
)

if(EXISTS "${_OPENMW_ANDROID_SDL2_PREFIX}/include/SDL.h")
    set(_OPENMW_ANDROID_SDL2_INCLUDE_DIR
        "${_OPENMW_ANDROID_SDL2_PREFIX}/include"
    )
elseif(EXISTS "${_OPENMW_ANDROID_SDL2_PREFIX}/include/SDL2/SDL.h")
    set(_OPENMW_ANDROID_SDL2_INCLUDE_DIR
        "${_OPENMW_ANDROID_SDL2_PREFIX}/include/SDL2"
    )
else()
    message(FATAL_ERROR
        "OpenMW Android SDL2 bridge: SDL.h was not found below "
        "${_OPENMW_ANDROID_SDL2_PREFIX}/include"
    )
endif()

if(NOT EXISTS "${_OPENMW_ANDROID_SDL2_LIBRARY}")
    message(FATAL_ERROR
        "OpenMW Android SDL2 bridge: libSDL2.so was not found at "
        "${_OPENMW_ANDROID_SDL2_LIBRARY}"
    )
endif()

if(NOT TARGET SDL2::SDL2)
    add_library(SDL2::SDL2 SHARED IMPORTED)
    set_target_properties(SDL2::SDL2 PROPERTIES
        IMPORTED_LOCATION "${_OPENMW_ANDROID_SDL2_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${_OPENMW_ANDROID_SDL2_INCLUDE_DIR}"
    )
endif()

set(SDL2_INCLUDE_DIRS "${_OPENMW_ANDROID_SDL2_INCLUDE_DIR}")
set(SDL2_LIBRARIES SDL2::SDL2)
set(SDL2_FOUND TRUE)
set(SDL2_VERSION "2.0.22")

unset(_OPENMW_ANDROID_SDL2_PREFIX)
unset(_OPENMW_ANDROID_SDL2_LIBRARY)
unset(_OPENMW_ANDROID_SDL2_INCLUDE_DIR)
