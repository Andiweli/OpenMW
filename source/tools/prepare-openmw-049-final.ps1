param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$CMakeFile = Join-Path $ProjectRoot 'buildscripts\CMakeLists.txt'
$BuildSh = Join-Path $ProjectRoot 'buildscripts\build.sh'

$FinalCommit = '675146bd8bce6245d78889f543b5c02a1e3936fe'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8)
}

function Replace-Exact([string]$Path, [string]$Description, [string]$Old, [string]$New) {
    $text = Read-Lf $Path
    if ($text.Contains($New)) {
        Write-Host "OpenMW 0.49 Final: $Description already applied."
        return
    }
    if (-not $text.Contains($Old)) {
        throw "Cannot apply '$Description'. $Path is not the expected CaveBros/v11.3 baseline."
    }
    Write-Utf8Lf $Path ($text.Replace($Old, $New))
    Write-Host "OpenMW 0.49 Final: applied $Description."
}

if (-not (Test-Path $CMakeFile) -or -not (Test-Path $BuildSh)) {
    throw 'Run this script from an OpenMW-Android project containing buildscripts.'
}

$RequiredPatchFiles = @(
    '0001-gl4es-shaders.patch',
    '0002-android-lifecycle.patch',
    '0003-android-ui.patch',
    '0004-static-osg-link.patch',
    '0005-gl4es-save-psa.patch',
    '0006-ndk-r26-stringstream-compat.patch',
    '0007-android-postprocessing-init.patch',
    '0008-android-deferred-postprocessing-enable.patch',
    '0009-android-postprocessing-gl-warmup.patch',
    '0010-android-postprocessing-stabilize-after-live-draws.patch'
)
foreach ($PatchName in $RequiredPatchFiles) {
    $PatchPath = Join-Path $ProjectRoot ('buildscripts\patches\openmw049-final\' + $PatchName)
    if (-not (Test-Path $PatchPath)) { throw "Missing v13 patch file: $PatchPath" }
}

$BoostAndroidHelper = Join-Path $ProjectRoot 'buildscripts\include\configure-boost-android.sh'
if (-not (Test-Path $BoostAndroidHelper)) {
    throw "Missing v13.10 Boost Android helper: $BoostAndroidHelper"
}

# Preserve the exact pre-v13 native build configuration once.
if (-not (Test-Path ($CMakeFile + '.pre-v13'))) { Copy-Item $CMakeFile ($CMakeFile + '.pre-v13') }
if (-not (Test-Path ($BuildSh + '.pre-v13'))) { Copy-Item $BuildSh ($BuildSh + '.pre-v13') }

$oldVersion = @'
# https://github.com/OpenMW/openmw/commits/master
set(OPENMW_VERSION 6d35b626cf5f3efac7748d9a5b697f12a780176b)
set(OPENMW_HASH SHA256=0939845b23de466e90401ba47a8d4d55d9ca7061118867c1f316adaccd4a0eaa)
'@
$newVersion = @'
# OpenMW 0.49.0 Final — immutable commit behind tag openmw-0.49.0
set(OPENMW_VERSION 675146bd8bce6245d78889f543b5c02a1e3936fe)
# ExternalProject currently does not enforce OPENMW_HASH; keep the commit immutable instead.
set(OPENMW_HASH "")
'@
Replace-Exact $CMakeFile 'official 0.49.0 Final engine pin' $oldVersion $newVersion

$oldSdl = @'
        INSTALL_COMMAND mkdir -p ${prefix}/lib/
        COMMAND cp libs/${app_abi}/libSDL2.so ${prefix}/lib/
        COMMAND cp -r <SOURCE_DIR>/include ${prefix}/
)
'@
$newSdl = @'
        INSTALL_COMMAND mkdir -p ${prefix}/lib/
        COMMAND cp libs/${app_abi}/libSDL2.so ${prefix}/lib/
        COMMAND cp -r <SOURCE_DIR>/include ${prefix}/
        COMMAND mkdir -p ${prefix}/lib/cmake/SDL2
        COMMAND cp ${CMAKE_SOURCE_DIR}/cmake/SDL2Config.cmake ${prefix}/lib/cmake/SDL2/
        COMMAND cp ${CMAKE_SOURCE_DIR}/cmake/SDL2ConfigVersion.cmake ${prefix}/lib/cmake/SDL2/
)
'@
Replace-Exact $CMakeFile 'SDL2::SDL2 CMake package bridge' $oldSdl $newSdl

$oldCommon = @'
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
        -DOPENMW_USE_SYSTEM_SQLITE3=OFF
        -DOPENMW_USE_SYSTEM_YAML_CPP=OFF
        -DOPENMW_USE_SYSTEM_ICU=ON
        -DOPENAL_INCLUDE_DIR=${prefix}/include/AL/
        -DBullet_INCLUDE_DIR=${prefix}/include/bullet/
        -DOSG_STATIC=TRUE
        -DMyGUI_LIBRARY=${prefix}/lib/libMyGUIEngineStatic.a
)
'@
$newCommon = @'
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
        -DBoost_DIR=${prefix}/lib/cmake/Boost-${BOOST_VERSION}
        -DSDL2_DIR=${prefix}/lib/cmake/SDL2
)
'@
# This transformation predates later v13.x additions inside OPENMW_COMMON
# (notably Boost_USE_STATIC_RUNTIME=ON). Do not require the whole target block
# to remain byte-for-byte identical after those later migrations.
#
# Accept an already-migrated block semantically when every required 0.49 Final
# argument is present. Only use the exact old->new replacement for a genuinely
# untouched CaveBros baseline.
$cmakeForOpenMwCommon = Read-Lf $CMakeFile
$requiredOpenMwCommonArgs = @(
    '-DBUILD_COMPONENTS_TESTS=OFF',
    '-DBUILD_OPENMW_TESTS=OFF',
    '-DOPENMW_USE_SYSTEM_SQLITE3=OFF',
    '-DOPENMW_USE_SYSTEM_YAML_CPP=OFF',
    '-DOPENMW_USE_SYSTEM_ICU=ON',
    '-DOPENMW_USE_SYSTEM_OSG=ON',
    '-DOPENMW_USE_SYSTEM_MYGUI=ON',
    '-DOPENMW_USE_SYSTEM_BULLET=ON',
    '-DOPENMW_USE_SYSTEM_RECASTNAVIGATION=OFF',
    '-DOPENMW_GL4ES_MANUAL_INIT=OFF',
    '-DBULLET_STATIC=TRUE',
    '-DOSG_STATIC=TRUE',
    '-DMYGUI_STATIC=TRUE',
    '-DBoost_USE_STATIC_LIBS=ON',
    '-DBoost_DIR=${prefix}/lib/cmake/Boost-${BOOST_VERSION}',
    '-DSDL2_DIR=${prefix}/lib/cmake/SDL2'
)

$missingOpenMwCommonArgs = @(
    $requiredOpenMwCommonArgs | Where-Object { -not $cmakeForOpenMwCommon.Contains($_) }
)

if ($missingOpenMwCommonArgs.Count -eq 0) {
    Write-Host 'OpenMW 0.49 Final: OpenMW 0.49 Final CMake arguments already applied.'
}
elseif ($cmakeForOpenMwCommon.Contains($oldCommon)) {
    Write-Utf8Lf $CMakeFile ($cmakeForOpenMwCommon.Replace($oldCommon, $newCommon))
    Write-Host 'OpenMW 0.49 Final: applied OpenMW 0.49 Final CMake arguments.'
}
else {
    $missingText = ($missingOpenMwCommonArgs -join ', ')
    throw "Cannot safely migrate 'OpenMW 0.49 Final CMake arguments': the file is in a partial/unknown state. Missing required arguments: $missingText"
}

# Harden the OpenMW ExternalProject's language mode explicitly. Upstream 0.49
# sets CMAKE_CXX_STANDARD=20 itself, but the Android/NDK build has now produced
# a translation unit where libc++ exposes std::stringstream without its C++20
# view() member. Make the requested standard visible at the ExternalProject
# configure boundary as well, rather than relying only on the nested project.
$cmakeForCxx20 = Read-Lf $CMakeFile
$cxx20Args = @(
    '-DCMAKE_CXX_STANDARD=20',
    '-DCMAKE_CXX_STANDARD_REQUIRED=ON',
    '-DCMAKE_CXX_EXTENSIONS=OFF'
)

$missingCxx20Args = @(
    $cxx20Args | Where-Object { -not $cmakeForCxx20.Contains($_) }
)

if ($missingCxx20Args.Count -eq 0) {
    Write-Host 'OpenMW 0.49 Final: explicit C++20 ExternalProject mode already applied.'
}
else {
    $cxx20Anchor = '        -DOPENMW_GL4ES_MANUAL_INIT=OFF'
    $anchorCount = ([regex]::Matches($cmakeForCxx20, [regex]::Escape($cxx20Anchor))).Count
    if ($anchorCount -ne 1) {
        throw "Cannot safely apply explicit C++20 mode: expected one OPENMW_GL4ES_MANUAL_INIT anchor, found $anchorCount."
    }

    $cxx20Replacement = $cxx20Anchor + "`n" +
        '        -DCMAKE_CXX_STANDARD=20' + "`n" +
        '        -DCMAKE_CXX_STANDARD_REQUIRED=ON' + "`n" +
        '        -DCMAKE_CXX_EXTENSIONS=OFF'

    $cmakeForCxx20 = $cmakeForCxx20.Replace($cxx20Anchor, $cxx20Replacement)
    Write-Utf8Lf $CMakeFile $cmakeForCxx20
    Write-Host 'OpenMW 0.49 Final: applied explicit C++20 ExternalProject mode.'
}

# OpenMW 0.49 Final uses Boost's installed CONFIG packages. The CaveBros
# Android build intentionally installs static Boost libraries built with
# `runtime-link=static`. Boost 1.83's generated CMake package rejects that
# variant unless Boost_USE_STATIC_RUNTIME is explicitly ON.
#
# Do not rebuild Boost: the installed libboost_*.a variant is already the
# intended one. Select it explicitly for OpenMW's find_package(Boost CONFIG).
$oldBoostRuntimeArgs = @'
        -DBoost_USE_STATIC_LIBS=ON
        -DBoost_DIR=${prefix}/lib/cmake/Boost-${BOOST_VERSION}
'@
$newBoostRuntimeArgs = @'
        -DBoost_USE_STATIC_LIBS=ON
        -DBoost_USE_STATIC_RUNTIME=ON
        -DBoost_DIR=${prefix}/lib/cmake/Boost-${BOOST_VERSION}
'@
Replace-Exact $CMakeFile 'Boost static runtime selection for OpenMW 0.49 Final' $oldBoostRuntimeArgs $newBoostRuntimeArgs

$oldPatches = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N -R < ${CMAKE_SOURCE_DIR}/patches/openmw/sdlfix.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw/shaders1.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw/postprocessing1.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw/cmakefix.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw/0001-loadingscreen-disable-for-now.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw/0009-windowmanagerimp-always-show-mouse-when-possible-pat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw/0010-android-fix-context-being-lost-on-app-minimize.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw/fix-build.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw/psa.patch &&
        cp ${CMAKE_SOURCE_DIR}/patches/openmw/android_main.cpp <SOURCE_DIR>/apps/openmw/android_main.cpp
)
'@

$previousFinalPatches = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0001-gl4es-shaders.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0002-android-lifecycle.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0003-android-ui.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0004-static-osg-link.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0005-gl4es-save-psa.patch
)
'@

$v13_15Patches = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0001-gl4es-shaders.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0002-android-lifecycle.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0003-android-ui.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0004-static-osg-link.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0005-gl4es-save-psa.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0006-ndk-r26-stringstream-compat.patch
)
'@

$v13_16Patches = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0001-gl4es-shaders.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0002-android-lifecycle.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0003-android-ui.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0004-static-osg-link.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0005-gl4es-save-psa.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0006-ndk-r26-stringstream-compat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0007-android-postprocessing-init.patch
)
'@

$v13_17Patches = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0001-gl4es-shaders.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0002-android-lifecycle.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0003-android-ui.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0004-static-osg-link.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0005-gl4es-save-psa.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0006-ndk-r26-stringstream-compat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0007-android-postprocessing-init.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0008-android-deferred-postprocessing-enable.patch
)
'@

$v13_18Patches = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0001-gl4es-shaders.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0002-android-lifecycle.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0003-android-ui.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0004-static-osg-link.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0005-gl4es-save-psa.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0006-ndk-r26-stringstream-compat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0007-android-postprocessing-init.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0008-android-deferred-postprocessing-enable.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0009-android-postprocessing-gl-warmup.patch
)
'@

$newPatches = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0001-gl4es-shaders.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0002-android-lifecycle.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0003-android-ui.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0004-static-osg-link.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0005-gl4es-save-psa.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0006-ndk-r26-stringstream-compat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0007-android-postprocessing-init.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0008-android-deferred-postprocessing-enable.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0009-android-postprocessing-gl-warmup.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw049-final/0010-android-postprocessing-stabilize-after-live-draws.patch
)
'@

$cmakeForPatchSet = Read-Lf $CMakeFile
if ($cmakeForPatchSet.Contains($newPatches)) {
    Write-Host 'OpenMW 0.49 Final: v13.23 Android patch set already applied.'
}
elseif ($cmakeForPatchSet.Contains($v13_18Patches)) {
    Write-Utf8Lf $CMakeFile ($cmakeForPatchSet.Replace($v13_18Patches, $newPatches))
    Write-Host 'OpenMW 0.49 Final: upgraded v13.18 to v13.23 late post-processing stabilization.'
}
elseif ($cmakeForPatchSet.Contains($v13_17Patches)) {
    Write-Utf8Lf $CMakeFile ($cmakeForPatchSet.Replace($v13_17Patches, $newPatches))
    Write-Host 'OpenMW 0.49 Final: upgraded v13.17 directly to v13.23 Android post-processing stabilization.'
}
elseif ($cmakeForPatchSet.Contains($v13_16Patches)) {
    Write-Utf8Lf $CMakeFile ($cmakeForPatchSet.Replace($v13_16Patches, $newPatches))
    Write-Host 'OpenMW 0.49 Final: upgraded v13.16 directly to v13.23 Android post-processing fixes.'
}
elseif ($cmakeForPatchSet.Contains($v13_15Patches)) {
    Write-Utf8Lf $CMakeFile ($cmakeForPatchSet.Replace($v13_15Patches, $newPatches))
    Write-Host 'OpenMW 0.49 Final: upgraded v13.15 patch set to v13.23 Android post-processing fixes.'
}
elseif ($cmakeForPatchSet.Contains($previousFinalPatches)) {
    Write-Utf8Lf $CMakeFile ($cmakeForPatchSet.Replace($previousFinalPatches, $newPatches))
    Write-Host 'OpenMW 0.49 Final: upgraded previous Final patch set to v13.23.'
}
elseif ($cmakeForPatchSet.Contains($oldPatches)) {
    Write-Utf8Lf $CMakeFile ($cmakeForPatchSet.Replace($oldPatches, $newPatches))
    Write-Host 'OpenMW 0.49 Final: applied v13.23 Android patch set.'
}
else {
    throw "Cannot safely migrate the OpenMW Android patch set: no known legacy/final/v13.15/v13.16/v13.17/v13.18/v13.23 patch chain was found."
}

$oldDeploy = @'
	cat "$SRC/openmw.cfg" | grep -v "data=" | grep -v "data-local=" >> "$DST/openmw/openmw.base.cfg"
	cat "$DIR/../app/openmw.base.cfg" >> "$DST/openmw/openmw.base.cfg"

	# licensing info
'@
$newDeploy = @'
	cat "$SRC/openmw.cfg" | grep -v "data=" | grep -v "data-local=" >> "$DST/openmw/openmw.base.cfg"
	cat "$DIR/../app/openmw.base.cfg" >> "$DST/openmw/openmw.base.cfg"

	# Immutable engine marker consumed by app/build.gradle. Prevents accidentally
	# packaging the old CaveBros 2024 development libopenmw.so after this upgrade.
	cat > "$DST/openmw/openmw-engine-version.txt" <<'EOF'
OpenMW 0.49.0 Final
commit=675146bd8bce6245d78889f543b5c02a1e3936fe
EOF

	# licensing info
'@
Replace-Exact $BuildSh 'final-engine runtime marker' $oldDeploy $newDeploy

$oldSymbols = @'
cp "./build/$ARCH/openmw-prefix/src/openmw-build/libopenmw.so" "./symbols/$ABI/libopenmw.so"
'@
$newSymbols = @'
OPENMW_SYMBOL_LIB=$(find "./build/$ARCH/openmw-prefix/" -iname "libopenmw.so" | head -n 1)
if [[ -z "$OPENMW_SYMBOL_LIB" ]]; then
        echo "ERROR: libopenmw.so was built but its unstripped symbol copy could not be located."
        exit 1
fi
cp "$OPENMW_SYMBOL_LIB" "./symbols/$ABI/libopenmw.so"
'@
Replace-Exact $BuildSh 'robust final libopenmw symbol lookup' $oldSymbols $newSymbols


# The legacy CaveBros build invokes plain `make -j$NCPU`, which builds every
# ExternalProject declared in buildscripts/CMakeLists.txt, including optional
# or historical helper projects that are not in OpenMW's dependency closure.
# One such stale project currently downloads from the removed
# github.com/Duron27/bzip2 repository and can abort an otherwise valid build.
#
# Build the explicit ExternalProject target `openmw` instead. CMake will still
# build every dependency declared by ExternalProject_Add(openmw DEPENDS ...),
# but unrelated/dead targets are not pulled in.
$oldMakeAll = @'
make -j$NCPU
'@
$newMakeOpenMw = @'
make -j$NCPU openmw
'@
Replace-Exact $BuildSh 'targeted OpenMW dependency build' $oldMakeAll $newMakeOpenMw

# Boost 1.83 is invoked with `toolset=clang`, but Boost.Build does not use the
# CXX environment variable to choose the clang executable automatically.
# Without an explicit tool configuration its clang-linux toolset searches for
# plain `clang++`, while the Android wrapper intentionally exposes the NDK
# cross compiler as $CXX (for arm64: aarch64-linux-android...-clang++).
#
# Configure B2 explicitly through a generated user-config.jam. The helper runs
# inside command_wrapper.sh, so it sees exactly the same Android CXX/PATH as the
# dependency build. <triple>none prevents B2 from adding a host-derived target
# triple on top of the NDK compiler wrapper, which already encodes Android/API.
$cmakeText = Read-Lf $CMakeFile
$boostStart = $cmakeText.IndexOf('ExternalProject_Add(boost')
$boostEnd = $cmakeText.IndexOf('ExternalProject_Add(ffmpeg', $boostStart)

if ($boostStart -lt 0 -or $boostEnd -le $boostStart) {
    throw "Cannot apply 'Boost Android cross compiler configuration': boost/ffmpeg ExternalProject boundaries were not found in $CMakeFile."
}

$boostBlockText = $cmakeText.Substring($boostStart, $boostEnd - $boostStart)
$boostChanged = $false

$boostHelperCommand = 'COMMAND ${wrapper_command} bash ${CMAKE_SOURCE_DIR}/include/configure-boost-android.sh <SOURCE_DIR>'
if (-not $boostBlockText.Contains($boostHelperCommand)) {
    $boostConfigurePattern = '(?m)^[ \t]*CONFIGURE_COMMAND[ \t]+\$\{wrapper_command\}[ \t]+<SOURCE_DIR>/bootstrap\.sh[ \t]*\n[ \t]*--prefix=\$\{prefix\}[ \t]*$'
    $boostConfigureMatches = [regex]::Matches($boostBlockText, $boostConfigurePattern)
    if ($boostConfigureMatches.Count -ne 1) {
        throw "Cannot apply 'Boost Android cross compiler configuration': expected one Boost bootstrap configure command, found $($boostConfigureMatches.Count)."
    }

    $oldBoostConfigure = $boostConfigureMatches[0].Value
    $indentMatch = [regex]::Match($oldBoostConfigure, '^[ \t]*')
    $indent = $indentMatch.Value
    $newBoostConfigure = $oldBoostConfigure + "`n" + $indent + $boostHelperCommand
    $boostBlockText = $boostBlockText.Replace($oldBoostConfigure, $newBoostConfigure)
    $boostChanged = $true
}

$boostUserConfigArg = '--user-config=<SOURCE_DIR>/android-user-config.jam'
if (-not $boostBlockText.Contains($boostUserConfigArg)) {
    $boostInstallPattern = '(?m)^([ \t]*)INSTALL_COMMAND[ \t]+\$\{wrapper_command\}[ \t]+\./b2[ \t]*$'
    $boostInstallMatches = [regex]::Matches($boostBlockText, $boostInstallPattern)
    if ($boostInstallMatches.Count -ne 1) {
        throw "Cannot apply 'Boost Android cross compiler configuration': expected one Boost b2 install command, found $($boostInstallMatches.Count)."
    }

    $oldBoostInstall = $boostInstallMatches[0].Value
    $indent = $boostInstallMatches[0].Groups[1].Value
    $newBoostInstall = $oldBoostInstall + "`n" + $indent + $boostUserConfigArg
    $boostBlockText = $boostBlockText.Replace($oldBoostInstall, $newBoostInstall)
    $boostChanged = $true
}

# Keep CaveBros' existing toolset=clang selection. The explicit user-config
# now supplies the compiler invocation that was previously missing.
if (-not [regex]::IsMatch($boostBlockText, '(?m)^[ \t]*toolset=clang[ \t]*$')) {
    throw "Cannot apply 'Boost Android cross compiler configuration': expected Boost toolset=clang in the CaveBros Boost block."
}

if ($boostChanged) {
    $cmakeText = $cmakeText.Substring(0, $boostStart) + $boostBlockText + $cmakeText.Substring($boostEnd)
    Write-Utf8Lf $CMakeFile $cmakeText
    Write-Host 'OpenMW 0.49 Final: applied explicit Boost Android clang configuration.'

    # Remove only failed/partial Boost state. Other completed dependencies stay.
    $BoostPrefix = Join-Path $ProjectRoot 'buildscripts\build\arm64\boost-prefix'
    if (Test-Path $BoostPrefix) {
        Remove-Item $BoostPrefix -Recurse -Force
        Write-Host 'OpenMW 0.49 Final: cleared stale Boost ExternalProject state.'
    }

    $PrefixArm64 = Join-Path $ProjectRoot 'buildscripts\prefix\arm64'
    $BoostHeaders = Join-Path $PrefixArm64 'include\boost'
    if (Test-Path $BoostHeaders) {
        Remove-Item $BoostHeaders -Recurse -Force
        Write-Host 'OpenMW 0.49 Final: removed partial Boost headers.'
    }

    $BoostLibDir = Join-Path $PrefixArm64 'lib'
    if (Test-Path $BoostLibDir) {
        Get-ChildItem $BoostLibDir -Filter 'libboost_*.a' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $BoostCmakeDir = Join-Path $BoostLibDir 'cmake'
        if (Test-Path $BoostCmakeDir) {
            Get-ChildItem $BoostCmakeDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'Boost-*' -or $_.Name -like 'boost_*' } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
else {
    Write-Host 'OpenMW 0.49 Final: explicit Boost Android clang configuration already applied.'
}

# CaveBros 0.3.5 has two independent LuaJIT references:
#
#   set(LUAJIT_VERSION v2.1.0-ROLLING)
#
# but ExternalProject_Add(luajit) does NOT use that variable. Its URL is
# hard-coded separately as:
#
#   URL https://github.com/LuaJIT/LuaJIT/archive/refs/tags/v2.1.ROLLING.tar.gz
#
# The hard-coded ref no longer exists. Pin both pieces explicitly to the same
# immutable LuaJIT commit used by the established Android build.
$LuaJitCommit = '505e2c03de35e2718eef0d2d3660712e06dadf1f'
$cmakeText = Read-Lf $CMakeFile
$luaJitChanged = $false

# 1) Locate exactly one LUAJIT_VERSION definition, regardless of its old value.
$luaJitVersionPattern = '(?m)^[ \t]*set[ \t]*\([ \t]*LUAJIT_VERSION[ \t]+[^)\r\n]+[ \t]*\)[ \t]*$'
$luaJitVersionMatches = [regex]::Matches($cmakeText, $luaJitVersionPattern)

if ($luaJitVersionMatches.Count -ne 1) {
    throw "Cannot apply 'exact CaveBros LuaJIT pin': expected exactly one LUAJIT_VERSION definition in $CMakeFile, found $($luaJitVersionMatches.Count)."
}

$currentLuaJitVersionLine = $luaJitVersionMatches[0].Value.Trim()
Write-Host "OpenMW 0.49 Final: detected LuaJIT definition: $currentLuaJitVersionLine" -ForegroundColor DarkCyan

$wantedLuaJitVersionLine = "set(LUAJIT_VERSION $LuaJitCommit)"
if ($currentLuaJitVersionLine -ne $wantedLuaJitVersionLine) {
    $cmakeText = [regex]::Replace(
        $cmakeText,
        $luaJitVersionPattern,
        $wantedLuaJitVersionLine,
        1
    )
    $luaJitChanged = $true
}

# 2) Locate the LuaJIT ExternalProject URL itself.
#    Do NOT assume that it references ${LUAJIT_VERSION}; CaveBros 0.3.5
#    hard-codes v2.1.ROLLING here.
$luaJitUrlPattern = '(?im)^[ \t]*URL[ \t]+https://github\.com/LuaJIT/LuaJIT/archive/[^\r\n \t]+\.tar\.gz[ \t]*$'
$luaJitUrlMatches = [regex]::Matches($cmakeText, $luaJitUrlPattern)

if ($luaJitUrlMatches.Count -ne 1) {
    throw "Cannot apply 'exact CaveBros LuaJIT pin': expected exactly one LuaJIT/LuaJIT archive URL in $CMakeFile, found $($luaJitUrlMatches.Count)."
}

$currentLuaJitUrlLine = $luaJitUrlMatches[0].Value.Trim()
Write-Host "OpenMW 0.49 Final: detected LuaJIT URL: $currentLuaJitUrlLine" -ForegroundColor DarkCyan

$wantedLuaJitUrlLine = 'URL https://github.com/LuaJIT/LuaJIT/archive/${LUAJIT_VERSION}.tar.gz'
if ($currentLuaJitUrlLine -ne $wantedLuaJitUrlLine) {
    $cmakeText = [regex]::Replace(
        $cmakeText,
        $luaJitUrlPattern,
        $wantedLuaJitUrlLine,
        1
    )
    $luaJitChanged = $true
}

if ($luaJitChanged) {
    Write-Utf8Lf $CMakeFile $cmakeText
    Write-Host 'OpenMW 0.49 Final: applied exact CaveBros LuaJIT commit pin.'

    # The failed hard-coded rolling URL is embedded in CMake's generated
    # ExternalProject download script. Remove only LuaJIT's generated state.
    $LuaJitPrefix = Join-Path $ProjectRoot 'buildscripts\build\arm64\luajit-prefix'
    if (Test-Path $LuaJitPrefix) {
        Remove-Item $LuaJitPrefix -Recurse -Force
        Write-Host 'OpenMW 0.49 Final: cleared stale LuaJIT ExternalProject state.'
    }

    # Also remove only the known obsolete/failed archive names if CMake/curl
    # left either one behind. Other dependency downloads remain untouched.
    $DownloadsDir = Join-Path $ProjectRoot 'buildscripts\downloads'
    foreach ($OldLuaJitArchive in @(
        'v2.1.ROLLING.tar.gz',
        'v2.1.0-ROLLING.tar.gz'
    )) {
        $OldLuaJitPath = Join-Path $DownloadsDir $OldLuaJitArchive
        if (Test-Path $OldLuaJitPath) {
            Remove-Item $OldLuaJitPath -Force
            Write-Host "OpenMW 0.49 Final: removed obsolete LuaJIT archive $OldLuaJitArchive."
        }
    }
}
else {
    Write-Host 'OpenMW 0.49 Final: exact CaveBros LuaJIT commit pin already applied.'
}

# Validate the SDL2 CMake bridge before copying it into an already populated
# prefix. v13.13 must not regress to the old hard-coded include/SDL2 path.
$SdlBridgeSource = Join-Path $ProjectRoot 'buildscripts\cmake\SDL2Config.cmake'
if (-not (Test-Path $SdlBridgeSource)) {
    throw "Missing SDL2 CMake bridge: $SdlBridgeSource"
}

$SdlBridgeText = Read-Lf $SdlBridgeSource
if (-not $SdlBridgeText.Contains('OpenMW Android v13.13')) {
    throw 'SDL2 CMake bridge is not the v13.13 layout-aware version.'
}

# If a previous native build already installed SDL into prefix, make the CMake
# package bridge available immediately; first-time builds install it via CMake.
$ExistingPrefix = Join-Path $ProjectRoot 'buildscripts\prefix\arm64\lib\cmake\SDL2'
if (Test-Path (Split-Path (Split-Path $ExistingPrefix -Parent) -Parent)) {
    New-Item -ItemType Directory -Force -Path $ExistingPrefix | Out-Null
    Copy-Item (Join-Path $ProjectRoot 'buildscripts\cmake\SDL2Config.cmake') $ExistingPrefix -Force
    Copy-Item (Join-Path $ProjectRoot 'buildscripts\cmake\SDL2ConfigVersion.cmake') $ExistingPrefix -Force

    $SdlIncludeRoot = Join-Path $ProjectRoot 'buildscripts\prefix\arm64\include'
    $SdlHeaderFlat = Join-Path $SdlIncludeRoot 'SDL.h'
    $SdlHeaderNested = Join-Path $SdlIncludeRoot 'SDL2\SDL.h'
    if (Test-Path $SdlHeaderFlat) {
        Write-Host "OpenMW 0.49 Final: SDL2 header layout detected: prefix/include/SDL.h" -ForegroundColor DarkCyan
    }
    elseif (Test-Path $SdlHeaderNested) {
        Write-Host "OpenMW 0.49 Final: SDL2 header layout detected: prefix/include/SDL2/SDL.h" -ForegroundColor DarkCyan
    }
    else {
        Write-Warning "SDL2 bridge copied, but SDL.h is not currently present under $SdlIncludeRoot. The SDL ExternalProject may need to install it first."
    }
}

$cmake = Read-Lf $CMakeFile
if (-not $cmake.Contains($FinalCommit)) { throw 'Final engine pin verification failed.' }
if ($cmake.Contains('postprocessing1.patch')) { throw 'Legacy postprocessing1.patch is still active.' }
if ($cmake.Contains('-R < ${CMAKE_SOURCE_DIR}/patches/openmw/sdlfix.patch')) { throw 'Legacy reverse SDL patch is still active.' }
if (-not $cmake.Contains('set(LUAJIT_VERSION 505e2c03de35e2718eef0d2d3660712e06dadf1f)')) {
    throw 'LuaJIT immutable commit verification failed.'
}
if (-not $cmake.Contains('URL https://github.com/LuaJIT/LuaJIT/archive/${LUAJIT_VERSION}.tar.gz')) {
    throw 'LuaJIT immutable archive URL verification failed.'
}
if ($cmake.Contains('v2.1.ROLLING') -or $cmake.Contains('v2.1.0-ROLLING')) {
    throw 'Legacy CaveBros LuaJIT rolling reference is still active.'
}
if (-not $cmake.Contains('COMMAND ${wrapper_command} bash ${CMAKE_SOURCE_DIR}/include/configure-boost-android.sh <SOURCE_DIR>')) {
    throw 'Boost Android compiler helper verification failed.'
}
if (-not $cmake.Contains('--user-config=<SOURCE_DIR>/android-user-config.jam')) {
    throw 'Boost Android user-config verification failed.'
}
if (-not $cmake.Contains('-DBoost_USE_STATIC_RUNTIME=ON')) {
    throw 'Boost static runtime selection verification failed.'
}
foreach ($RequiredOpenMwArg in $requiredOpenMwCommonArgs) {
    if (-not $cmake.Contains($RequiredOpenMwArg)) {
        throw "OpenMW 0.49 Final CMake argument verification failed: missing $RequiredOpenMwArg"
    }
}
foreach ($RequiredCxx20Arg in $cxx20Args) {
    if (-not $cmake.Contains($RequiredCxx20Arg)) {
        throw "OpenMW 0.49 Final C++20 mode verification failed: missing $RequiredCxx20Arg"
    }
}
if (-not $cmake.Contains('0006-ndk-r26-stringstream-compat.patch')) {
    throw 'OpenMW NDK libc++ compatibility patch verification failed.'
}
if (-not $cmake.Contains('0007-android-postprocessing-init.patch')) {
    throw 'OpenMW Android post-processing initialization patch verification failed.'
}
if (-not $cmake.Contains('0008-android-deferred-postprocessing-enable.patch')) {
    throw 'OpenMW Android deferred post-processing enable patch verification failed.'
}
if (-not $cmake.Contains('0009-android-postprocessing-gl-warmup.patch')) {
    throw 'OpenMW Android post-processing GL warm-up patch verification failed.'
}
if (-not $cmake.Contains('0010-android-postprocessing-stabilize-after-live-draws.patch')) {
    throw 'OpenMW Android late post-processing stabilization patch verification failed.'
}

$buildShText = Read-Lf $BuildSh
if (-not $buildShText.Contains('make -j$NCPU openmw')) {
    throw 'Targeted OpenMW native build verification failed.'
}

Write-Host ''
Write-Host 'OpenMW Android native source setup: READY' -ForegroundColor Green
Write-Host "Pinned engine: OpenMW 0.49.0 Final / $FinalCommit"
