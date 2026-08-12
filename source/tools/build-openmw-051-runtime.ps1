param(
    [switch]$NoLto,
    [switch]$SkipPrepare,
    [ValidateRange(1, 64)]
    [int]$Jobs = 6
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

if (-not $SkipPrepare) {
    & (Join-Path $PSScriptRoot 'prepare-openmw-051-runtime.ps1')
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required by the CaveBros native build scripts.'
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported project path for this WSL build wrapper: $WindowsPath"
    }
    $DriveLetter = $Matches[1].ToLowerInvariant()
    $RelativePart = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($RelativePart)) { return "/mnt/$DriveLetter" }
    return "/mnt/$DriveLetter/" + (($RelativePart -replace '\\', '/').TrimStart('/'))
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$BuildDir = "$WslProject/buildscripts"
$LtoArg = if ($NoLto) { '' } else { '--lto' }
$JobsArg = "--jobs $Jobs"
$WindowsBuildScript = Join-Path $ProjectRoot 'tools\.openmw-051-runtime-build.sh'
$WslBuildScript = "$WslProject/tools/.openmw-051-runtime-build.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

cd __BUILD_DIR__

CMAKE_VERSION="$(cmake --version | head -n1 | awk '{print $3}')"
if [ "$(printf '%s\n' 3.16 "$CMAKE_VERSION" | sort -V | head -n1)" != "3.16" ]; then
    echo "ERROR: OpenMW 0.51 Final requires CMake >= 3.16; found $CMAKE_VERSION" >&2
    exit 2
fi

echo "CMake $CMAKE_VERSION OK"
echo "OpenMW 0.51 Patch 3: GL4ES core/vfs-mw runtime payload"
echo "Shadows/post-processing/OMWFX remain runtime-disabled for this gate"
echo "Dependency versions intentionally remain unchanged"

BUILD_LOG="$PWD/openmw-051-runtime-native-build.log"
rm -f "$BUILD_LOG"
echo "Native build log: $BUILD_LOG"

set +e
./build.sh --arch arm64 __LTO_ARG__ __JOBS_ARG__ 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}
set -e

if [ "$BUILD_RC" -ne 0 ]; then
    echo
    echo "============================================================"
    echo "OpenMW 0.51 Patch 3 runtime build FAILED (exit $BUILD_RC)"
    echo "Full log: $BUILD_LOG"
    echo "Likely root-cause lines:"
    echo "============================================================"
    grep -n -E -i \
        '(^|[^a-z])(fatal error:|error:|cmake error|undefined reference|cannot find|could not find|no rule to make target|FAILED:|ninja: build stopped|collect2: error|ld: error|make\[[0-9]+\]: \*\*\*)' \
        "$BUILD_LOG" | tail -n 220 || true
    exit "$BUILD_RC"
fi

SOURCE="$PWD/build/arm64/openmw-prefix/src/openmw"
BUILD="$PWD/build/arm64/openmw-prefix/src/openmw-build"
APP="$PWD/../app"
JNI="$APP/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PWD/symbols/arm64-v8a/libopenmw.so"
ASSETS="$APP/src/main/assets/libopenmw"

if [ ! -f "$SOURCE/CMakeLists.txt" ] || ! grep -Eq 'set\(OPENMW_VERSION_MINOR[[:space:]]+51\)' "$SOURCE/CMakeLists.txt"; then
    echo "ERROR: completed source is not OpenMW 0.51.x." >&2
    exit 21
fi
if ! grep -Fq 'OPENMW_ANDROID_051_RUNTIME_BASELINE' "$SOURCE/apps/openmw/androidmain.cpp"; then
    echo "ERROR: Patch 3 Android runtime bridge is missing from the built source." >&2
    exit 22
fi
if ! grep -Fq 'OPENMW_ANDROID_051_LOADINGSCREEN_NO_FB_COPY' "$SOURCE/apps/openmw/mwgui/loadingscreen.cpp"; then
    echo "ERROR: Patch 3 Android loading-screen workaround is missing from the built source." >&2
    exit 23
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GL4ES_CORE_INLINE' "$SOURCE/files/shaders/lib/core/vertex.h.glsl" \
    || ! grep -Fq 'OPENMW_ANDROID_051_GL4ES_CORE_INLINE' "$SOURCE/files/shaders/lib/core/fragment.h.glsl"; then
    echo "ERROR: Patch 3 GL4ES core shader inlining is missing from the built source." >&2
    exit 24
fi

for item in \
    "$JNI" \
    "$SYMBOLS" \
    "$ASSETS/resources/version" \
    "$ASSETS/openmw/defaults.bin" \
    "$ASSETS/openmw/openmw.base.cfg" \
    "$ASSETS/openmw/openmw-engine-version.txt"; do
    if [ ! -s "$item" ]; then
        echo "ERROR: OpenMW 0.51 runtime payload item is missing/empty: $item" >&2
        exit 24
    fi
done

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
ACTUAL_MARKER="$(cat "$ASSETS/openmw/openmw-engine-version.txt")"
if [ "$ACTUAL_MARKER" != "$EXPECTED_MARKER" ]; then
    echo "ERROR: OpenMW 0.51 engine marker mismatch." >&2
    printf 'Actual marker:\n%s\n' "$ACTUAL_MARKER" >&2
    exit 25
fi
if ! grep -Fq '0.51.0' "$ASSETS/resources/version"; then
    echo "ERROR: deployed resources/version is not OpenMW 0.51.0." >&2
    exit 26
fi
if ! grep -aFq 'OpenMW 0.51.0' "$SYMBOLS"; then
    echo "ERROR: unstripped symbol library does not identify as OpenMW 0.51.0." >&2
    exit 27
fi
if ! grep -aFq 'OpenMW 0.51.0' "$JNI"; then
    echo "ERROR: packaged stripped libopenmw.so does not identify as OpenMW 0.51.0." >&2
    exit 28
fi

# Verify that the APK copy is actually stripped and not the large symbol image.
SYMBOL_SIZE=$(stat -c %s "$SYMBOLS")
JNI_SIZE=$(stat -c %s "$JNI")
if [ "$JNI_SIZE" -ge "$SYMBOL_SIZE" ]; then
    echo "ERROR: packaged libopenmw.so was not reduced by llvm-strip." >&2
    echo "symbol bytes=$SYMBOL_SIZE packaged bytes=$JNI_SIZE" >&2
    exit 29
fi

READELF="$PWD/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
if [ ! -x "$READELF" ]; then
    echo "ERROR: llvm-readelf is missing from the pinned Android NDK toolchain." >&2
    exit 30
fi
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo "ERROR: packaged libopenmw.so still contains DWARF debug sections." >&2
    exit 30
fi

FULLSCREEN="$ASSETS/resources/shaders/compatibility/fullscreen_tri.vert"
SHADOWCAST="$ASSETS/resources/shaders/compatibility/shadowcasting.vert"
SHADOWRECV="$ASSETS/resources/shaders/compatibility/shadows_fragment.glsl"
DEBUGVERT="$ASSETS/resources/shaders/compatibility/debug.vert"
DEBUGFRAG="$ASSETS/resources/shaders/compatibility/debug.frag"
COREVERT="$ASSETS/resources/shaders/lib/core/vertex.h.glsl"
COREFRAG="$ASSETS/resources/shaders/lib/core/fragment.h.glsl"
ESMFALLBACKS="$ASSETS/resources/vfs-mw/scripts/omw/esmfallbacks.lua"

for item in "$FULLSCREEN" "$SHADOWCAST" "$SHADOWRECV" "$DEBUGVERT" "$DEBUGFRAG" "$COREVERT" "$COREFRAG" "$ESMFALLBACKS"; do
    if [ ! -f "$item" ]; then
        echo "ERROR: expected Patch-3 runtime resource is missing: $item" >&2
        exit 31
    fi
done

if grep -Fq 'uniform vec2 scaling =' "$FULLSCREEN" \
    || grep -Fq 'uniform bool useDiffuseMapForShadowAlpha =' "$SHADOWCAST" \
    || grep -Fq 'uniform bool alphaTestShadows =' "$SHADOWCAST" \
    || grep -Fq 'uniform bool useAdvancedShader =' "$DEBUGVERT" \
    || grep -Fq 'uniform bool useAdvancedShader =' "$DEBUGFRAG"; then
    echo "ERROR: minimal OpenMW 0.51 GL4ES uniform-initializer patch is missing." >&2
    exit 32
fi

if grep -Fq '@link "lib/core/vertex.glsl"' "$COREVERT" \
    || grep -Fq '@link "lib/core/fragment.glsl"' "$COREFRAG" \
    || ! grep -Fq 'OPENMW_ANDROID_051_GL4ES_CORE_INLINE' "$COREVERT" \
    || ! grep -Fq 'OPENMW_ANDROID_051_GL4ES_CORE_INLINE' "$COREFRAG"; then
    echo "ERROR: OpenMW 0.51 GL4ES core helper inlining is missing." >&2
    exit 32
fi

if ! grep -Fq 'vfs-mw' "$ASSETS/openmw/openmw.base.cfg"; then
    echo "ERROR: OpenMW 0.51 base config lost the internal resources/vfs-mw data path." >&2
    exit 32
fi

# The old 0.50 shadow receiver must not be present yet; shadows remain deferred.
if grep -Fq 'OPENMW_ANDROID_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOWRECV" \
    || ! grep -Fq 'uniform sampler2DShadow' "$SHADOWRECV" \
    || ! grep -Fq 'shadow2DProj(' "$SHADOWRECV"; then
    echo "ERROR: Patch 2 expected the native OpenMW 0.51 shadow receiver with shadows disabled." >&2
    exit 33
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
SYMBOL_SHA=$(sha256sum "$SYMBOLS" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PWD/openmw-051-runtime-libopenmw.sha256"

printf '\nOpenMW 0.51 Patch 3 runtime payload: SUCCESS\n'
printf 'Packaged/stripped lib: %s (%s bytes)\n' "$JNI" "$JNI_SIZE"
printf 'Symbol/unstripped lib: %s (%s bytes)\n' "$SYMBOLS" "$SYMBOL_SIZE"
printf 'Packaged SHA-256: %s\n' "$JNI_SHA"
printf 'Symbol SHA-256:   %s\n' "$SYMBOL_SHA"
printf 'Resources:       %s\n' "$(cat "$ASSETS/resources/version")"
printf 'Engine marker:   OpenMW 0.51.0 Final / f4bec41444214a7903bebd178389ca22ca13f646\n'
printf 'Next: assemble/install APK; runtime gate keeps Shadows=OFF and Post Processing=OFF.\n'
'@

$ShellScript = $ShellScript.Replace('__BUILD_DIR__', (Quote-Bash $BuildDir))
$ShellScript = $ShellScript.Replace('__LTO_ARG__', $LtoArg)
$ShellScript = $ShellScript.Replace('__JOBS_ARG__', $JobsArg)
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsBuildScript, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'Building OpenMW 0.51.0 Final Patch 3 runtime payload for arm64-v8a...' -ForegroundColor Cyan
Write-Host "This rebuild uses Patch 3 and limits native parallelism to $Jobs job(s)." -ForegroundColor Yellow
Write-Host 'The large unstripped binary will be kept separately under buildscripts\symbols\arm64-v8a.' -ForegroundColor DarkGray

try {
    & wsl.exe --exec bash $WslBuildScript
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $WindowsBuildScript -Force -ErrorAction SilentlyContinue
}

$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'
$Marker = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$ResourceVersion = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\version'

foreach ($Required in @($JniLib, $SymbolLib, $Marker, $ResourceVersion)) {
    if (-not (Test-Path $Required)) { throw "Patch 2 output verification failed: missing $Required" }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
$ActualMarker = [IO.File]::ReadAllText($Marker).Replace("`r`n", "`n")
if ($ActualMarker -ne $ExpectedMarker) {
    throw "Patch 2 Windows-side engine marker mismatch: $($ActualMarker -replace "`n", ' | ')"
}
if (-not ([IO.File]::ReadAllText($ResourceVersion).Trim().StartsWith('0.51.0'))) {
    throw 'Patch 2 Windows-side resources/version is not OpenMW 0.51.0.'
}

$JniSize = (Get-Item $JniLib).Length
$SymbolSize = (Get-Item $SymbolLib).Length
if ($JniSize -ge $SymbolSize) {
    throw "Patch 2 strip verification failed: packaged=$JniSize symbol=$SymbolSize"
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 3 runtime payload is ready for Android Studio / Gradle.' -ForegroundColor Green
Write-Host "Packaged libopenmw.so: $JniLib ($JniSize bytes)"
Write-Host "Unstripped symbols:    $SymbolLib ($SymbolSize bytes)"
Write-Host "Packaged SHA-256:      $((Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host 'Expected first native log line on device: OpenMW version 0.51.0'
Write-Host 'Runtime gate: Shadows OFF, Post Processing OFF, OMWFX not installed into the OpenMW VFS.'
