cmake_minimum_required(VERSION 3.2.0)

# https://github.com/libjpeg-turbo/libjpeg-turbo/releases
set(LIBJPEG_TURBO_VERSION 1.5.3)
set(LIBJPEG_TURBO_HASH SHA256=b24890e2bb46e12e72a79f7e965f409f4e16466d00e1dd15d93d73ee6b592523)

# http://www.libpng.org/pub/png/libpng.html
set(LIBPNG_VERSION 1.6.42)
set(LIBPNG_HASH SHA256=505e70834d35383537b6491e7ae8641f1a4bed1876dbfe361201fc80868d88ca)

# https://www.freetype.org/index.html#news
set(FREETYPE2_VERSION 2.13.2)
set(FREETYPE2_HASH SHA256=1ac27e16c134a7f2ccea177faba19801131116fd682efc1f5737037c5db224b5)

# https://github.com/kcat/openal-soft/releases
set(OPENAL_VERSION 1.23.1)
set(OPENAL_HASH SHA256=8ac17e4e3b32c1af3d5508acfffb838640669b4274606b7892aa796ca9d7467f)

# https://www.boost.org/users/download/#live
set(BOOST_VERSION 1.83.0)
set(BOOST_HASH SHA256=0c6049764e80aa32754acd7d4f179fd5551d8172a83b71532ae093e7384e98da)

# https://www.ffmpeg.org/download.html
set(FFMPEG_VERSION 6.1)
set(FFMPEG_HASH SHA256=42093549751b582cf0f338a21a3664f52e0a9fbe0d238d3c992005e493607d0e)

# https://www.libsdl.org/download-2.0.php
set(SDL2_VERSION 2.0.22)
set(SDL2_HASH SHA256=fe7cbf3127882e3fc7259a75a0cb585620272c51745d3852ab9dd87960697f2e)

# https://github.com/bulletphysics/bullet3/releases
set(BULLET_VERSION 3.25)
set(BULLET_HASH SHA256=baa642c906576d4d98d041d0acb80d85dd6eff6e3c16a009b1abf1ccd2bc0a61)

#https://github.com/MyGUI/mygui/releases
set(MYGUI_VERSION 3.4.3)
set(MYGUI_HASH SHA256=33c91b531993047e77cace36d6fea73634b8c17bd0ed193d4cd12ac7c6328abd)

# https://github.com/sisah2/gl4es/releases
set(GL4ES_VERSION 5ac069d82ad8ca2cc3c574484e4c5bad880db83e)
set(GL4ES_HASH SHA256=b565e717c7d192e936bda25f3cb90ad8db398af56414ec08294b6716574c1a6d)

# https://github.com/openscenegraph/OpenSceneGraph/releases
set(OSG_VERSION 69cfecebfb6dc703b42e8de39eed750a84a87489)
set(OSG_HASH SHA256=aea196550f02974d6d09291c5d83b51ca6a03b3767e234a8c0e21322927d1e12)

# https://github.com/lz4/lz4/releases
set(LZ4_VERSION 1.9.3)
set(LZ4_HASH SHA256=030644df4611007ff7dc962d981f390361e6c97a34e5cbc393ddfbe019ffe2c1)

# https://luajit.org/download.html
set(LUAJIT_VERSION 505e2c03de35e2718eef0d2d3660712e06dadf1f)
set(LUAJIT_HASH SHA256=409f7fe570d3c16558e594421c47bdd130238323c9d6fd6c83dedd2aaeb082a8)

# OpenMW 0.51.0 Final Android runtime gate â€” immutable commit behind tag openmw-0.51.0
set(OPENMW_VERSION f4bec41444214a7903bebd178389ca22ca13f646)
# ExternalProject currently does not enforce OPENMW_HASH; keep the commit immutable instead.
set(OPENMW_HASH "")

# https://github.com/unicode-org/icu/
set(LIBICU_VERSION 70-1)
set(LIBICU_HASH SHA256=4013d7aff8a34bae410664bdb16554d7eda03654b22627b9284ab55a685492d4)

# End of configurable options

project(openmw-android)

include(ExternalProject)

set(wrapper_command ${CMAKE_BINARY_DIR}/command_wrapper.sh)
set(ndk_triplet ${NDK_TRIPLET})
set(download_dir ${CMAKE_SOURCE_DIR}/downloads/)
set(prefix ${CMAKE_INSTALL_PREFIX})
set(host ${ndk_triplet})
set(android_platform android-${ANDROID_API})
set(app_abi ${ABI})

set(COMMON_CMAKE_ARGS
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_SOURCE_DIR}/toolchain/ndk/build/cmake/android.toolchain.cmake
        -DANDROID_ABI=${app_abi}
        -DANDROID_PLATFORM=${android_platform}
        -DANDROID_STL=c++_shared
        -DANDROID_LD=deprecated
        -DANDROID_CPP_FEATURES=rtti\ exceptions
        -DCMAKE_C_FLAGS=-I${prefix}/include/\ $ENV{CFLAGS}
        -DCMAKE_CXX_FLAGS=-I${prefix}/include/\ $ENV{CXXFLAGS}
        -DCMAKE_SHARED_LINKER_FLAGS=$ENV{LDFLAGS}
        -DCMAKE_BUILD_TYPE=${BUILD_TYPE}
        -DCMAKE_DEBUG_POSTFIX=
        -DCMAKE_INSTALL_PREFIX=${prefix}
        -DCMAKE_FIND_ROOT_PATH=${prefix}
)

set(COMMON_NDK_BUILD_FLAGS
        NDK_PROJECT_PATH=.
        APP_BUILD_SCRIPT=<SOURCE_DIR>/Android.mk
        APP_PLATFORM=${android_platform}
        APP_ABI=${app_abi}
        APP_LD=deprecated
        LOCAL_LDFLAGS=$ENV{LDFLAGS}
        -j4
)

set(COMMON_AUTOCONF_FLAGS
        --enable-static
        --disable-shared
        --prefix=${prefix}
)

# ffmpeg doesn't like --host, so sandwich it between adding --host to the flags
set(ffmpeg_configure_flags ${COMMON_AUTOCONF_FLAGS})
if (${BUILD_TYPE} STREQUAL "debug")
        # ffmpeg fails to compile if we have asm enabled and optimizations disabled, so disable both
        set(ffmpeg_configure_flags ${ffmpeg_configure_flags} --disable-asm --disable-optimizations)
endif()

if ((${ARCH} STREQUAL "x86_64") OR (${ARCH} STREQUAL "x86") OR (${ARCH} STREQUAL "arm64"))
        # ffmpeg fails to link with assembly optimizations on x86-64
        set(ffmpeg_configure_flags ${ffmpeg_configure_flags} --disable-asm)
endif()

set(COMMON_AUTOCONF_FLAGS
        --host=${host}
        ${COMMON_AUTOCONF_FLAGS}
)

if (${ARCH} STREQUAL "arm")
        set(ffmpeg_configure_flags ${ffmpeg_configure_flags} --enable-thumb)
endif()

# on x86 enabling simd results in text relocations, which are banned on Android
set(libjpeg_turbo_flags "")
if (${ARCH} STREQUAL "x86")
        set(libjpeg_turbo_flags ${libjpeg_turbo_flags} --without-simd)
endif()

ExternalProject_Add(bzip2

        URL https://github.com/Duron27/bzip2/archive/refs/tags/v1.tar.gz
        #URL_HASH SHA256=
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>
        ${COMMON_CMAKE_ARGS}

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
)

ExternalProject_Add(libjpeg-turbo
        URL https://sourceforge.net/projects/libjpeg-turbo/files/${LIBJPEG_TURBO_VERSION}/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz
        URL_HASH ${LIBJPEG_TURBO_HASH}
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} <SOURCE_DIR>/configure
        ${COMMON_AUTOCONF_FLAGS}
        ${libjpeg_turbo_flags}

        BUILD_COMMAND ${wrapper_command} $(MAKE) PROGRAMS=

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install-libLTLIBRARIES install-data-am
)

set(libicu_flags
        --disable-tests
        --disable-samples
        --disable-icuio
        --disable-extras
        --with-cross-build=${CMAKE_SOURCE_DIR}/build/icu-host-build)

ExternalProject_Add(libicu
        URL https://github.com/unicode-org/icu/archive/refs/tags/release-${LIBICU_VERSION}.zip
        URL_HASH ${LIBICU_HASH}
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} <SOURCE_DIR>/icu4c/source/configure
        ${COMMON_AUTOCONF_FLAGS}
        ${libicu_flags}

        BUILD_COMMAND ${wrapper_command} $(MAKE) check_PROGRAMS= bin_PROGRAMS=

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install check_PROGRAMS= bin_PROGRAMS=
)

ExternalProject_Add(libpng
        URL http://prdownloads.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz
#        URL_HASH ${LIBPNG_HASH}
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} <SOURCE_DIR>/configure
        ${COMMON_AUTOCONF_FLAGS}

        BUILD_COMMAND ${wrapper_command} $(MAKE) check_PROGRAMS= bin_PROGRAMS=

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install check_PROGRAMS= bin_PROGRAMS=
)

ExternalProject_Add(freetype2
        # FreeType's Savannah endpoint occasionally returns transient 5xx errors.
        # ExternalProject tries URL entries in order, so use SourceForge first and
        # retain Savannah as an independent fallback. The verified upstream hash
        # also lets CMake reuse a valid archive from DOWNLOAD_DIR safely.
        URL
        https://sourceforge.net/projects/freetype/files/freetype2/${FREETYPE2_VERSION}/freetype-${FREETYPE2_VERSION}.tar.gz/download
        https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE2_VERSION}.tar.gz
        URL_HASH ${FREETYPE2_HASH}
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} <SOURCE_DIR>/configure
        ${COMMON_AUTOCONF_FLAGS}
        --with-png=no

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
)

ExternalProject_Add(openal
        URL https://github.com/kcat/openal-soft/archive/${OPENAL_VERSION}.tar.gz
        #URL_HASH ${OPENAL_HASH}
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>
        ${COMMON_CMAKE_ARGS}
        -DALSOFT_EXAMPLES=OFF
        -DALSOFT_TESTS=OFF
        -DALSOFT_UTILS=OFF
        -DALSOFT_NO_CONFIG_UTIL=ON
        -DALSOFT_BACKEND_OPENSL=ON
        -DALSOFT_BACKEND_WAVE=OFF

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
)

ExternalProject_Add(boost
        URL https://github.com/boostorg/boost/releases/download/boost-${BOOST_VERSION}/boost-${BOOST_VERSION}.tar.gz
        URL_HASH ${BOOST_HASH}
        DOWNLOAD_DIR ${download_dir}


BUILD_IN_SOURCE 1

        CONFIGURE_COMMAND ${wrapper_command} <SOURCE_DIR>/bootstrap.sh
        --prefix=${prefix}
        COMMAND ${wrapper_command} bash ${CMAKE_SOURCE_DIR}/include/configure-boost-android.sh <SOURCE_DIR>

        BUILD_COMMAND ""

        INSTALL_COMMAND ${wrapper_command} ./b2
        --user-config=<SOURCE_DIR>/android-user-config.jam
        -j4
        --with-filesystem
        --with-program_options
        --with-system
        --with-iostreams
        --ignore-site-config
        toolset=clang
        architecture=${BOOST_ARCH}
        address-model=${BOOST_ADDRESS_MODEL}
        cflags=$ENV{CFLAGS}
        cxxflags=$ENV{CXXFLAGS}
        variant=release
        target-os=android
        threading=multi
        threadapi=pthread
        link=static
        runtime-link=static
        install
        COMMAND llvm-ranlib ${prefix}/lib/libboost_filesystem.a
        COMMAND llvm-ranlib ${prefix}/lib/libboost_program_options.a
        COMMAND llvm-ranlib ${prefix}/lib/libboost_system.a
        COMMAND llvm-ranlib ${prefix}/lib/libboost_iostreams.a
)

ExternalProject_Add(ffmpeg
        URL http://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.bz2
        #URL_HASH ${FFMPEG_HASH}
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} <SOURCE_DIR>/configure
        ${ffmpeg_configure_flags}
        --target-os=android
        --enable-cross-compile
        --cross-prefix=llvm-
        --cc=${host}-clang
        --arch=${ARCH}
        --cpu=${FFMPEG_CPU}
        --enable-version3
        --enable-pic
        --disable-everything
        --disable-doc
        --disable-programs
        --disable-autodetect
        --disable-iconv
        --enable-decoder=mp3
        --enable-demuxer=mp3
        --enable-decoder=bink
        --enable-decoder=binkaudio_rdft
        --enable-decoder=binkaudio_dct
        --enable-demuxer=bink
        --enable-demuxer=wav
        --enable-decoder=pcm_*
        --enable-decoder=vp8
        --enable-decoder=vp9
        --enable-decoder=opus
        --enable-decoder=vorbis
        --enable-demuxer=matroska
        --enable-demuxer=ogg

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
)

ExternalProject_Add(sdl2
        URL https://www.libsdl.org/release/SDL2-${SDL2_VERSION}.tar.gz
        URL_HASH ${SDL2_HASH}
        DOWNLOAD_DIR ${download_dir}


        CONFIGURE_COMMAND ""

        BUILD_COMMAND ${wrapper_command} ndk-build
        ${COMMON_NDK_BUILD_FLAGS}

        INSTALL_COMMAND mkdir -p ${prefix}/lib/
        COMMAND cp libs/${app_abi}/libSDL2.so ${prefix}/lib/
        COMMAND cp -r <SOURCE_DIR>/include ${prefix}/
        COMMAND mkdir -p ${prefix}/lib/cmake/SDL2
        COMMAND cp ${CMAKE_SOURCE_DIR}/cmake/SDL2Config.cmake ${prefix}/lib/cmake/SDL2/
        COMMAND cp ${CMAKE_SOURCE_DIR}/cmake/SDL2ConfigVersion.cmake ${prefix}/lib/cmake/SDL2/
)

ExternalProject_Add(bullet
        URL https://github.com/bulletphysics/bullet3/archive/${BULLET_VERSION}.tar.gz
        #URL_HASH ${BULLET_HASH}
        DOWNLOAD_DIR ${download_dir}

        PATCH_COMMAND patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/bullet-fix-cmake.patch

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>
        ${COMMON_CMAKE_ARGS}
        -DBUILD_BULLET2_DEMOS=OFF
        -DBUILD_CPU_DEMOS=OFF
        -DBUILD_UNIT_TESTS=OFF
        -DBUILD_EXTRAS=OFF
        -DUSE_DOUBLE_PRECISION=ON
        -DBULLET2_MULTITHREADING=ON

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND $(MAKE) install
)

ExternalProject_Add(gl4es
        URL https://github.com/sisah2/gl4es/archive/${GL4ES_VERSION}.tar.gz
        #URL_HASH ${GL4ES_HASH}
        DOWNLOAD_DIR ${download_dir}

        BUILD_COMMAND ${wrapper_command} ndk-build
        ${COMMON_NDK_BUILD_FLAGS}

        INSTALL_COMMAND mkdir -p ${prefix}/lib/
        COMMAND cp libs/${app_abi}/libGL.so ${prefix}/lib/
        COMMAND cp -r <SOURCE_DIR>/include ${prefix}/
        COMMAND cp -r <SOURCE_DIR>/include ${prefix}/include/gl4es/
)

ExternalProject_Add(mygui
        DEPENDS freetype2

        URL https://github.com/MyGUI/mygui/archive/MyGUI${MYGUI_VERSION}.tar.gz
        URL_HASH ${MYGUI_HASH}
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>
        ${COMMON_CMAKE_ARGS}
        -DMYGUI_RENDERSYSTEM=1
        -DMYGUI_BUILD_DEMOS=OFF
        -DMYGUI_BUILD_TOOLS=OFF
        -DMYGUI_BUILD_PLUGINS=OFF
        -DMYGUI_DONT_USE_OBSOLETE=ON
        -DFREETYPE_FT2BUILD_INCLUDE_DIR=${prefix}/include/freetype2/

        -DMYGUI_STATIC=ON

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
)

ExternalProject_Add(lz4
        URL https://github.com/lz4/lz4/archive/v${LZ4_VERSION}.tar.gz
        URL_HASH ${LZ4_HASH}
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>/build/cmake/
        ${COMMON_CMAKE_ARGS}
        -DBUILD_STATIC_LIBS=ON
        -DBUILD_SHARED_LIBS=OFF

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
)

set(LUAJIT_MAKE_FLAGS
        HOST_CC=${LUAJIT_HOST_CC}
        CFLAGS=
        TARGET_CFLAGS=$ENV{CFLAGS}
        CROSS=llvm-
        STATIC_CC=${host}-clang
        DYNAMIC_CC=${host}-clang\ -fPIC
        TARGET_LD=${host}-clang
        PREFIX=${prefix}
)

ExternalProject_Add(luajit
URL https://github.com/LuaJIT/LuaJIT/archive/${LUAJIT_VERSION}.tar.gz
#        URL_HASH ${LUAJIT_HASH}
        DOWNLOAD_DIR ${download_dir}

        BUILD_IN_SOURCE 1

        CONFIGURE_COMMAND ""

        BUILD_COMMAND ${wrapper_command} $(MAKE) amalg
        ${LUAJIT_MAKE_FLAGS}

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
        ${LUAJIT_MAKE_FLAGS}
        COMMAND bash -c "rm ${prefix}/lib/libluajit*.so*"
)

ExternalProject_Add(zlib
        URL https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz
#        URL_HASH SHA256=629380c90a77b964d896ed37163f5c3a34f6e6d897311f1df2a7016355c45eff
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>
        ${COMMON_CMAKE_ARGS}

        BUILD_COMMAND ${wrapper_command} $(MAKE)
        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
)

ExternalProject_Add(libxml
        DEPENDS zlib

        URL https://github.com/GNOME/libxml2/archive/refs/tags/v2.12.5.tar.gz
        #URL_HASH SHA256=0ae29f4bad60d9d65fe6e6b8bc96147b743f9075b63c13d4aeb0391c0046c442
        DOWNLOAD_DIR ${download_dir}

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>
        ${COMMON_CMAKE_ARGS}
        -DBUILD_SHARED_LIBS=OFF
        -DLIBXML2_WITH_THREADS=ON
        -DLIBXML2_WITH_CATALOG=OFF
        -DLIBXML2_WITH_ICONV=OFF
        -DLIBXML2_WITH_LZMA=OFF
        -DLIBXML2_WITH_PROGRAMS=OFF
        -DLIBXML2_WITH_PYTHON=OFF
        -DLIBXML2_WITH_TESTS=OFF
        -DLIBXML2_WITH_ZLIB=ON

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
)

set(LIBCOLLADA_PATCH patch -d <SOURCE_DIR> -p0 -t -N < ${CMAKE_SOURCE_DIR}/patches/libcollada-minizip-fix.patch)

ExternalProject_Add(libcollada
        DEPENDS libxml boost

        URL https://github.com/rdiankov/collada-dom/archive/v2.5.0.tar.gz
        URL_HASH SHA256=3be672407a7aef60b64ce4b39704b32816b0b28f61ebffd4fbd02c8012901e0d
        DOWNLOAD_DIR ${download_dir}

        PATCH_COMMAND ${LIBCOLLADA_PATCH}

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>
        ${COMMON_CMAKE_ARGS}
        -DBoost_USE_STATIC_LIBS=ON
        -DBoost_USE_STATIC_RUNTIME=ON
        -DBoost_NO_SYSTEM_PATHS=ON
        -DBoost_INCLUDE_DIR=${prefix}/include
        -DCMAKE_CXX_FLAGS=-Dauto_ptr=unique_ptr\ -I${prefix}/include/\ $ENV{CXXFLAGS}

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND ${wrapper_command} $(MAKE) install
)

set(OSG_COMMON
        -DOPENGL_PROFILE="GL1"
        -DDYNAMIC_OPENTHREADS=OFF
        -DDYNAMIC_OPENSCENEGRAPH=OFF
        -DBUILD_OSG_PLUGIN_OSG=ON
        -DBUILD_OSG_PLUGIN_DAE=ON
        -DBUILD_OSG_PLUGIN_DDS=ON
        -DBUILD_OSG_PLUGIN_TGA=ON
        -DBUILD_OSG_PLUGIN_BMP=ON
        -DBUILD_OSG_PLUGIN_JPEG=ON
        -DBUILD_OSG_PLUGIN_PNG=ON
        -DBUILD_OSG_PLUGIN_FREETYPE=ON
        -DJPEG_INCLUDE_DIR=${prefix}/include/
        -DPNG_INCLUDE_DIR=${prefix}/include/
        -DFREETYPE_DIR=${prefix}
        -DOSG_VERTEX_BUFFER_HINT=VBO
        -DCOLLADA_INCLUDE_DIR=${prefix}/include/collada-dom2.5
        -DCOLLADA_DIR=${prefix}/include/collada-dom2.5/1.4
        -DOSG_CPP_EXCEPTIONS_AVAILABLE=TRUE
        -DOSG_GL1_AVAILABLE=ON
        -DOSG_GL2_AVAILABLE=OFF
        -DOSG_GL3_AVAILABLE=OFF
        -DOSG_GLES1_AVAILABLE=OFF
        -DOSG_GLES2_AVAILABLE=OFF
        -DOSG_GL_LIBRARY_STATIC=OFF
        -DOSG_GL_DISPLAYLISTS_AVAILABLE=OFF
        -DOSG_GL_MATRICES_AVAILABLE=ON
        -DOSG_GL_VERTEX_FUNCS_AVAILABLE=ON
        -DOSG_GL_VERTEX_ARRAY_FUNCS_AVAILABLE=ON
        -DOSG_GL_FIXED_FUNCTION_AVAILABLE=ON
        -DBUILD_OSG_APPLICATIONS=OFF
        -DBUILD_OSG_PLUGINS_BY_DEFAULT=OFF
        -DBUILD_OSG_DEPRECATED_SERIALIZERS=OFF
)

set(OSG_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/disable-polygon-offset.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/remove-lib-prefix-from-plugins.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/fix-freetype-include-dirs.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/0001-Replace-Atomic-impl-with-std-atomic.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/0002-BufferObject-make-numClients-atomic.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/0004-IncrementalCompileOperation-wrap-some-stuff-in-atomi.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/force-add-plugins.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/dae_collada.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/android-shadow-texture-compat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/osg/0005-CullSettings-make-inheritanceMask-atomic-to-silence-.patch
)

ExternalProject_Add(osg
        DEPENDS libjpeg-turbo libpng gl4es freetype2 libcollada

        URL https://github.com/openmw/osg/archive/${OSG_VERSION}.tar.gz
#        URL_HASH ${OSG_HASH}
        DOWNLOAD_DIR ${download_dir}

        PATCH_COMMAND ${OSG_PATCH}

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>
        ${COMMON_CMAKE_ARGS}
        ${OSG_COMMON}
        -DCMAKE_CXX_FLAGS=-Dauto_ptr=unique_ptr\ -I${prefix}/include/\ $ENV{CXXFLAGS}

        BUILD_COMMAND ${wrapper_command} $(MAKE)

        INSTALL_COMMAND mkdir -p <SOURCE_DIR>/3rdparty/build/libpng <SOURCE_DIR>/3rdparty/build/libjpeg <SOURCE_DIR>/3rdparty/build/freetype
        COMMAND $(MAKE) install
)

set(OPENMW_COMMON
        -DBUILD_BSATOOL=0
        -DBUILD_NIFTEST=0
        -DBUILD_ESMTOOL=0
        -DBUILD_LAUNCHER=0
        -DBUILD_MWINIIMPORTER=0
        -DBUILD_ESSIMPORTER=0
        -DBUILD_OPENCS=0
        -DBUILD_NAVMESHTOOL=0
        -DBUILD_WIZARD=0
        -DBUILD_MYGUI_PLUGIN=0
        -DBUILD_BULLETOBJECTTOOL=0
        -DBUILD_COMPONENTS_TESTS=OFF
        -DBUILD_OPENMW_TESTS=OFF
        -DOPENMW_USE_SYSTEM_SQLITE3=OFF
        -DOPENMW_USE_SYSTEM_YAML_CPP=OFF
        -DOPENMW_USE_SYSTEM_ICU=ON
        -DOPENMW_USE_SYSTEM_OSG=ON
        -DOPENMW_USE_SYSTEM_MYGUI=ON
        -DOPENMW_USE_SYSTEM_BULLET=ON
        -DOPENMW_USE_SYSTEM_RECASTNAVIGATION=OFF
        -DOPENMW_GL4ES_MANUAL_INIT=OFF
        -DCMAKE_CXX_STANDARD=20
        -DCMAKE_CXX_STANDARD_REQUIRED=ON
        -DCMAKE_CXX_EXTENSIONS=OFF
        -DOPENAL_INCLUDE_DIR=${prefix}/include/AL/
        -DBullet_INCLUDE_DIR=${prefix}/include/bullet/
        -DBULLET_STATIC=TRUE
        -DOSG_STATIC=TRUE
        -DMYGUI_STATIC=TRUE
        -DMyGUI_LIBRARY=${prefix}/lib/libMyGUIEngineStatic.a
        -DBoost_USE_STATIC_LIBS=ON
        -DBoost_USE_STATIC_RUNTIME=ON
        -DBoost_DIR=${prefix}/lib/cmake/Boost-${BOOST_VERSION}
        -DSDL2_DIR=${prefix}/lib/cmake/SDL2
)

set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw051-final/0001-ndk-r26-stringstream-compat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw051-final/0002-static-osg-link.patch &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-ndk-r26-format.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-runtime-baseline.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-gl4es-core-inline.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-graphics-followup.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-graphics-followup2.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-graphics-followup3.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-graphics-followup4.py <SOURCE_DIR>
)
ExternalProject_Add(openmw
        DEPENDS boost openal osg mygui ffmpeg sdl2 bullet lz4 luajit libicu

        URL https://github.com/OpenMW/openmw/archive/${OPENMW_VERSION}.tar.gz
        #URL_HASH ${OPENMW_HASH}
        DOWNLOAD_DIR ${download_dir}

        PATCH_COMMAND ${OPENMW_PATCH}

        CONFIGURE_COMMAND ${wrapper_command} cmake <SOURCE_DIR>
        ${COMMON_CMAKE_ARGS}
        ${OPENMW_COMMON}

        BUILD_COMMAND $(MAKE)

        INSTALL_COMMAND ""
)
