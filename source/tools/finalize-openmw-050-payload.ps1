$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = '47d78e004bc182def2904986f8bb54aea1f4b3ae'
$ExpectedBinaryMarker = 'Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at '

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required to finalize the OpenMW Android native payload.'
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported project path for this WSL payload finalizer: $WindowsPath"
    }
    $DriveLetter = $Matches[1].ToLowerInvariant()
    $RelativePart = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($RelativePart)) { return "/mnt/$DriveLetter" }
    return "/mnt/$DriveLetter/" + (($RelativePart -replace '\\', '/').TrimStart('/'))
}

$Project = Convert-WindowsPathToWsl $ProjectRoot
$TempWin = Join-Path $ProjectRoot 'tools\.openmw-050-finalize-payload.sh'
$TempWsl = "$Project/tools/.openmw-050-finalize-payload.sh"

$Script = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT=__PROJECT__
FINAL_COMMIT='47d78e004bc182def2904986f8bb54aea1f4b3ae'
EXPECTED_MARKER='Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at '
SHADOW_MARKER='OPENMW_ANDROID_GLES2_MANUAL_SHADOW_COMPARE'
SHADOW_BINARY_MARKER='Android GLES2 manual shadow comparison enabled'
BUILD_ROOT="$PROJECT/buildscripts/build/arm64/openmw-prefix"
BUILD_DIR="$BUILD_ROOT/src/openmw-build"
SOURCE_DIR="$BUILD_ROOT/src/openmw"
APP="$PROJECT/app"
ABI_DIR="$APP/src/main/jniLibs/arm64-v8a"
SYMBOL_DIR="$PROJECT/buildscripts/symbols/arm64-v8a"
ASSET_ROOT="$APP/src/main/assets/libopenmw"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: OpenMW 0.50 source tree is missing: $SOURCE_DIR" >&2
    exit 2
fi
if ! grep -Eq 'set\(OPENMW_VERSION_MINOR[[:space:]]+50\)' "$SOURCE_DIR/CMakeLists.txt"; then
    echo "ERROR: native source tree is not OpenMW 0.50.x." >&2
    exit 3
fi
if ! grep -Fq "set(OPENMW_VERSION $FINAL_COMMIT)" "$PROJECT/buildscripts/CMakeLists.txt"; then
    echo "ERROR: buildscripts/CMakeLists.txt is not pinned to the expected OpenMW 0.50 Final commit." >&2
    exit 4
fi

# Locate the finished engine library. CMake/ExternalProject may expose the
# target as a regular file or as a symlink, so do not restrict find to -type f.
# build.sh also already deploys a stripped copy to jniLibs and an unstripped
# copy to symbols; both are valid fallback sources for finalization.
LIB=""
if [ -s "$BUILD_DIR/libopenmw.so" ]; then
    LIB="$BUILD_DIR/libopenmw.so"
fi
if [ -z "$LIB" ]; then
    LIB=$(find "$BUILD_ROOT" -iname libopenmw.so -print -quit 2>/dev/null || true)
fi
if [ -z "$LIB" ] && [ -s "$SYMBOL_DIR/libopenmw.so" ]; then
    LIB="$SYMBOL_DIR/libopenmw.so"
fi
if [ -z "$LIB" ] && [ -s "$ABI_DIR/libopenmw.so" ]; then
    LIB="$ABI_DIR/libopenmw.so"
fi
if [ -z "${LIB:-}" ] || [ ! -s "$LIB" ]; then
    echo "ERROR: finished OpenMW 0.50 libopenmw.so could not be found in the CMake tree, symbols directory, or Android jniLibs." >&2
    exit 5
fi

# The 0.49 build contains the same Android startup marker, so also verify the
# embedded engine version before accepting an already-packaged fallback copy.
if ! grep -aFq 'OpenMW 0.50.0' "$LIB"; then
    echo "ERROR: located libopenmw.so is not an OpenMW 0.50.0 engine binary: $LIB" >&2
    exit 6
fi
if ! grep -aFq "$EXPECTED_MARKER" "$LIB"; then
    echo "ERROR: OpenMW 0.50 libopenmw.so does not contain the Android startup stabilization marker." >&2
    exit 7
fi
if ! grep -aFq "$SHADOW_BINARY_MARKER" "$LIB"; then
    echo "ERROR: OpenMW 0.50 libopenmw.so does not contain the Android GLES2 manual-shadow runtime marker." >&2
    exit 7
fi

OSG_TEXTURE_CPP="$PROJECT/buildscripts/build/arm64/osg-prefix/src/osg/src/osg/Texture.cpp"
if [ ! -f "$OSG_TEXTURE_CPP" ] || ! grep -Fq "$SHADOW_MARKER" "$OSG_TEXTURE_CPP"; then
    echo "ERROR: built OSG source tree does not contain the Android GLES2 shadow-texture compatibility patch." >&2
    exit 7
fi

echo "Using finished OpenMW library: $LIB"

for file in resources defaults.bin gamecontrollerdb.txt openmw.cfg; do
    if [ ! -e "$BUILD_DIR/$file" ]; then
        echo "ERROR: generated OpenMW 0.50 payload item is missing: $BUILD_DIR/$file" >&2
        exit 7
    fi
done
if [ ! -f "$BUILD_DIR/resources/version" ] || ! grep -Fq '0.50.0' "$BUILD_DIR/resources/version"; then
    echo "ERROR: generated resources are not OpenMW 0.50.0 resources." >&2
    exit 8
fi

SHADOW_FRAGMENT="$BUILD_DIR/resources/shaders/compatibility/shadows_fragment.glsl"
if [ ! -f "$SHADOW_FRAGMENT" ] || ! grep -Fq "$SHADOW_MARKER" "$SHADOW_FRAGMENT"; then
    echo "ERROR: generated OpenMW resources do not contain the Android GLES2 manual shadow shader." >&2
    exit 8
fi
if grep -Fq 'sampler2DShadow' "$SHADOW_FRAGMENT" || grep -Fq 'shadow2DProj' "$SHADOW_FRAGMENT"; then
    echo "ERROR: generated Android shadow receiver shader still uses unsupported hardware shadow samplers." >&2
    exit 8
fi

# Re-deploy the complete native payload from the already-finished 0.50 build.
mkdir -p "$ABI_DIR" "$SYMBOL_DIR"
copy_if_different() {
    local src="$1"
    local dst="$2"
    if [ -e "$dst" ] && [ "$(readlink -f "$src")" = "$(readlink -f "$dst")" ]; then
        return 0
    fi
    cp -f "$src" "$dst"
}
copy_if_different "$LIB" "$SYMBOL_DIR/libopenmw.so"
copy_if_different "$LIB" "$ABI_DIR/libopenmw.so"

# Refresh companion shared libraries when available. These are dependencies, not engine-version markers.
for spec in \
    "$PROJECT/buildscripts/prefix/arm64/lib/libopenal.so:libopenal.so" \
    "$PROJECT/buildscripts/prefix/arm64/lib/libSDL2.so:libSDL2.so" \
    "$PROJECT/buildscripts/prefix/arm64/lib/libGL.so:libGL.so" \
    "$PROJECT/buildscripts/prefix/arm64/lib/libcollada-dom2.5-dp.so:libcollada-dom2.5-dp.so"; do
    src=${spec%%:*}
    dst=${spec##*:}
    if [ -s "$src" ]; then cp -f "$src" "$ABI_DIR/$dst"; fi
done

CXX_SHARED=$(find "$PROJECT/buildscripts/toolchain/arm64/sysroot/usr/lib" -type f -name libc++_shared.so -print -quit 2>/dev/null || true)
if [ -n "$CXX_SHARED" ]; then cp -f "$CXX_SHARED" "$ABI_DIR/libc++_shared.so"; fi

STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
if [ -x "$STRIP" ]; then
    "$STRIP" "$ABI_DIR/libopenmw.so"
fi
if ! grep -aFq "$EXPECTED_MARKER" "$ABI_DIR/libopenmw.so"; then
    echo "ERROR: packaged libopenmw.so lost the Android startup stabilization marker." >&2
    exit 8
fi

# Replace only generated libopenmw assets. Android-owned OMWFX assets live elsewhere.
rm -rf "$ASSET_ROOT"
mkdir -p "$ASSET_ROOT/openmw"
cp -a "$BUILD_DIR/resources" "$ASSET_ROOT/"
cp -f "$BUILD_DIR/defaults.bin" "$ASSET_ROOT/openmw/defaults.bin"
cp -f "$BUILD_DIR/gamecontrollerdb.txt" "$ASSET_ROOT/openmw/gamecontrollerdb.txt"
# OpenMW 0.50 also emits user-data in its generated openmw.cfg. Android owns
# that setting in app/openmw.base.cfg, so filter the generated copy to avoid
# the fatal "option 'user-data' cannot be specified more than once" error.
grep -v -E '^(data|data-local|user-data)=' "$BUILD_DIR/openmw.cfg" > "$ASSET_ROOT/openmw/openmw.base.cfg"
cat "$APP/openmw.base.cfg" >> "$ASSET_ROOT/openmw/openmw.base.cfg"
cp -f "$PROJECT/3rdparty-licenses.txt" "$ASSET_ROOT/3rdparty-licenses.txt"

# Write the immutable marker last, after all 0.50 files are in place.
printf '%s\n%s\n' \
    'OpenMW 0.50.0 Final' \
    "commit=$FINAL_COMMIT" > "$ASSET_ROOT/openmw/openmw-engine-version.txt"

MARKER_TEXT=$(cat "$ASSET_ROOT/openmw/openmw-engine-version.txt")
if [[ "$MARKER_TEXT" != *'OpenMW 0.50.0 Final'* ]] || [[ "$MARKER_TEXT" != *"$FINAL_COMMIT"* ]]; then
    echo "ERROR: final engine marker verification failed." >&2
    exit 9
fi

# Verify Android's user-data option is present exactly once.
USER_DATA_COUNT=$(grep -c '^user-data=' "$ASSET_ROOT/openmw/openmw.base.cfg" || true)
if [ "$USER_DATA_COUNT" -ne 1 ]; then
    echo "ERROR: finalized openmw.base.cfg must contain exactly one user-data entry; found $USER_DATA_COUNT." >&2
    exit 10
fi

# Final completeness check mirrors the critical Gradle payload inputs.
for item in \
    "$ASSET_ROOT/resources/version" \
    "$ASSET_ROOT/resources/shaders/compatibility/fullscreen_tri.vert" \
    "$ASSET_ROOT/resources/shaders/compatibility/shadowcasting.vert" \
    "$ASSET_ROOT/resources/shaders/compatibility/shadows_fragment.glsl" \
    "$ASSET_ROOT/openmw/defaults.bin" \
    "$ASSET_ROOT/openmw/openmw.base.cfg" \
    "$ASSET_ROOT/openmw/openmw-engine-version.txt" \
    "$ASSET_ROOT/openmw/gamecontrollerdb.txt" \
    "$ASSET_ROOT/3rdparty-licenses.txt" \
    "$ABI_DIR/libopenmw.so"; do
    if [ ! -e "$item" ]; then
        echo "ERROR: finalized Android payload is incomplete: $item" >&2
        exit 11
    fi
done

FINAL_SHADOW_FRAGMENT="$ASSET_ROOT/resources/shaders/compatibility/shadows_fragment.glsl"
if ! grep -Fq "$SHADOW_MARKER" "$FINAL_SHADOW_FRAGMENT" || grep -Fq 'sampler2DShadow' "$FINAL_SHADOW_FRAGMENT" || grep -Fq 'shadow2DProj' "$FINAL_SHADOW_FRAGMENT"; then
    echo "ERROR: finalized Android payload does not contain the GLES2 manual shadow receiver shader." >&2
    exit 12
fi

LIB_SHA=$(sha256sum "$ABI_DIR/libopenmw.so" | awk '{print $1}')
echo
echo 'OpenMW 0.50 Android payload finalization: SUCCESS'
echo "Engine marker: OpenMW 0.50.0 Final / $FINAL_COMMIT"
echo "Packaged lib SHA-256: $LIB_SHA"
echo "Verified binary marker: $EXPECTED_MARKER"
echo "Verified GLES2 shadow binary marker: $SHADOW_BINARY_MARKER"
echo "Verified GLES2 shadow shader marker: $SHADOW_MARKER"
echo "Verified openmw.base.cfg: exactly one user-data entry"
'@

$Script = $Script.Replace('__PROJECT__', (Quote-Bash $Project))
$Script = $Script -replace "`r`n", "`n"
[IO.File]::WriteAllText($TempWin, $Script, [Text.UTF8Encoding]::new($false))

try {
    & wsl.exe --exec bash $TempWsl
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $TempWin -Force -ErrorAction SilentlyContinue
}

$Marker = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$ExpectedMarkerText = "OpenMW 0.50.0 Final`ncommit=$FinalCommit`n"
$ActualMarkerText = [IO.File]::ReadAllText($Marker).Replace("`r`n", "`n")
if ($ActualMarkerText -ne $ExpectedMarkerText) {
    throw "Windows-side marker verification failed. Actual marker: $($ActualMarkerText -replace "`n", ' | ')"
}

Write-Host ''
Write-Host 'Payload is ready for Android Studio / Gradle.' -ForegroundColor Green
Write-Host 'No native rebuild is required.' -ForegroundColor Green
