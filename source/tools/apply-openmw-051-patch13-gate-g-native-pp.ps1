param(
    [ValidateRange(1, 32)]
    [int]$Jobs = 6
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported project path for WSL: $WindowsPath"
    }
    $DriveLetter = $Matches[1].ToLowerInvariant()
    $RelativePart = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($RelativePart)) { return "/mnt/$DriveLetter" }
    return "/mnt/$DriveLetter/" + (($RelativePart -replace '\\', '/').TrimStart('/'))
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$Adjustments = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\vfs\shaders\adjustments.omwfx'
$PatchSha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch13-libopenmw.sha256'

foreach ($Required in @(
    $MarkerFile, $JniLib, $SourceRoot, $BuildRoot, $RuntimePatcher,
    $MainActivity, $BuildGradle, $Adjustments
)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 13 requires the working OpenMW 0.51 Patch-12k project tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit"
if ((Read-Lf $MarkerFile).Trim() -ne $ExpectedMarker) {
    throw 'Patch 13 refused a non-0.51.0-Final runtime payload.'
}

$PatcherText = Read-Lf $RuntimePatcher
$MainText = Read-Lf $MainActivity
$GradleText = Read-Lf $BuildGradle
$AdjustmentsText = Read-Lf $Adjustments

if (-not $PatcherText.Contains('OPENMW_ANDROID_051_GATE_G_PP_INIT')) {
    throw 'Patch 13 permanent native PP initialization is missing from apply-android-runtime-baseline.py.'
}
if (-not $MainText.Contains('OpenMW 0.51 Gate G runtime: shadows=false (test isolation), postProcessing=true, chain=adjustments, omwfx=false')) {
    throw 'Patch 13 launcher Gate-G runtime settings are missing from MainActivity.kt.'
}
if (-not $GradleText.Contains('openmw-051-patch13-libopenmw.sha256')) {
    throw 'Patch 13 Gradle stale-native safety gate is missing.'
}
if (-not $AdjustmentsText.Contains('author = "OpenMW"') -or
    -not $AdjustmentsText.Contains('passes = main;') -or
    $AdjustmentsText.Contains('omw_SamplerNormals')) {
    throw 'Bundled adjustments.omwfx does not match the expected simple native OpenMW technique.'
}

# Gate F must remain structurally present. Gate G only changes native PP setup
# and launcher runtime selection; shadow math/resources are not touched.
foreach ($Marker in @(
    'OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS',
    'OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING',
    'OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME',
    'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS',
    'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE',
    'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING'
)) {
    if (-not $PatcherText.Contains($Marker)) {
        throw "Patch 13 refused a runtime patcher that lost Gate-F marker: $Marker"
    }
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch13-gate-g-native-pp.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch13-gate-g-native-pp.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT=__PROJECT__
JOBS=__JOBS__
SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
BUILD="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-runtime-baseline.py"
JNI="$PROJECT/app/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PROJECT/buildscripts/symbols/arm64-v8a/libopenmw.so"
MARKER="$PROJECT/app/src/main/assets/libopenmw/openmw/openmw-engine-version.txt"
STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
POST_CPP="$SOURCE/apps/openmw/mwrender/postprocessor.cpp"
POST_HPP="$SOURCE/apps/openmw/mwrender/postprocessor.hpp"
MWST="$SOURCE/components/sceneutil/mwshadowtechnique.cpp"
SHADOW_CPP="$SOURCE/components/sceneutil/shadow.cpp"
SHADOW_FRAG="$SOURCE/files/shaders/compatibility/shadows_fragment.glsl"
SHADOW_CAST="$SOURCE/files/shaders/compatibility/shadowcasting.vert"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
if [[ "$(cat "$MARKER")" != "$EXPECTED_MARKER" ]]; then
    echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2
    exit 40
fi
if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
    echo 'ERROR: pinned NDK llvm-strip/llvm-readelf is missing.' >&2
    exit 41
fi

# Re-run the permanent semantic Android patcher. It is idempotent and preserves
# the already device-tested Gate-F shadow stack while adding Gate-G PP init.
python3 "$PATCHER" "$SOURCE"

if ! grep -Fq 'OPENMW_ANDROID_051_GATE_G_PP_INIT' "$POST_CPP" || \
   ! grep -Fq 'OPENMW_ANDROID_051_GATE_G_PP_INIT' "$POST_HPP"; then
    echo 'ERROR: Gate-G PP initialization marker is missing after patching.' >&2
    exit 42
fi
if ! grep -Fq 'OpenMW 0.51 Android Gate G PP init:' "$POST_CPP"; then
    echo 'ERROR: Gate-G PP runtime log marker is missing from source.' >&2
    exit 43
fi

# Verify that the first Android dimensions are acquired before HUD/FBO creation.
python3 - "$POST_CPP" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = text.index('OPENMW_ANDROID_051_GATE_G_PP_INIT')
viewport = text.index('mHUDCamera->setViewport(0, 0, mWidth, mHeight);')
frame0 = text.index('createObjectsForFrame(0);')
late = text.index('osg::GLExtensions* ext = gc->getState()->get<osg::GLExtensions>();')
if not (marker < viewport < frame0 < late):
    raise SystemExit('Gate-G PP initialization ordering verification failed')
PY

for marker in \
    OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS \
    OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING \
    OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME \
    OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS; do
    if ! grep -Fq "$marker" "$MWST"; then
        echo "ERROR: stable Gate-F shadow marker lost: $marker" >&2
        exit 44
    fi
done
if ! grep -Fq 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP' "$SHADOW_CPP"; then
    echo 'ERROR: Gate-F orthographic shadow baseline was lost.' >&2
    exit 45
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_FRAG" || \
   ! grep -Fq 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' "$SHADOW_CAST"; then
    echo 'ERROR: Gate-F GLES2 shadow baseline was lost.' >&2
    exit 46
fi

echo
echo 'OpenMW 0.51 Gate G source: READY'
echo '  Native PP size initialized before HUD/FBO creation'
echo '  Runtime test chain: adjustments only'
echo '  OMWFX overlay: OFF'
echo '  Shadows: forced OFF by launcher for first Gate-G A/B'
echo '  Patch-12k shadow source retained unchanged'
echo
echo "Incrementally rebuilding OpenMW only (parallelism=$JOBS) ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
if [ "${#BUILT_LIBS[@]}" -eq 0 ]; then
    echo "ERROR: rebuilt libopenmw.so not found under $BUILD" >&2
    exit 47
fi
if [ "${#BUILT_LIBS[@]}" -gt 1 ]; then
    printf 'ERROR: multiple rebuilt libopenmw.so candidates found:\n' >&2
    printf '  %s\n' "${BUILT_LIBS[@]}" >&2
    exit 48
fi
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

for lib in "$SYMBOLS" "$JNI"; do
    if ! grep -aFq 'OpenMW 0.51.0' "$lib"; then
        echo "ERROR: rebuilt library does not identify as OpenMW 0.51.0: $lib" >&2
        exit 49
    fi
    if ! grep -aFq 'OpenMW 0.51 Android Gate G PP init:' "$lib"; then
        echo "ERROR: Gate-G PP runtime marker is missing from rebuilt library: $lib" >&2
        exit 50
    fi
    if grep -aFq 'OPENMW_SHADOW_GL_DIAG' "$lib"; then
        echo "ERROR: obsolete Patch-12f shadow diagnostic marker returned: $lib" >&2
        exit 51
    fi
done

SYMBOL_SIZE=$(stat -c %s "$SYMBOLS")
JNI_SIZE=$(stat -c %s "$JNI")
if [ "$JNI_SIZE" -ge "$SYMBOL_SIZE" ]; then
    echo "ERROR: packaged library was not stripped (packaged=$JNI_SIZE symbols=$SYMBOL_SIZE)." >&2
    exit 52
fi
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo 'ERROR: packaged libopenmw.so still contains DWARF debug sections.' >&2
    exit 53
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
SYMBOL_SHA=$(sha256sum "$SYMBOLS" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch13-libopenmw.sha256"

echo
echo 'OpenMW 0.51 Patch 13 Gate-G native PP: SUCCESS'
printf 'Packaged/stripped lib: %s (%s bytes)\n' "$JNI" "$JNI_SIZE"
printf 'Symbol/unstripped lib: %s (%s bytes)\n' "$SYMBOLS" "$SYMBOL_SIZE"
printf 'Packaged SHA-256: %s\n' "$JNI_SHA"
printf 'Symbol SHA-256:   %s\n' "$SYMBOL_SHA"
echo 'Next: assemble/reinstall the APK and test native adjustments with shadows OFF.'
'@

$ShellScript = $ShellScript.Replace('__PROJECT__', (Quote-Bash $WslProject))
$ShellScript = $ShellScript.Replace('__JOBS__', $Jobs.ToString())
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsHelper, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 13 - Gate G Native Post-Processing' -ForegroundColor Cyan
Write-Host 'Native technique: adjustments only.' -ForegroundColor Green
Write-Host 'OMWFX remains OFF; shadows are forced OFF for this isolated test.' -ForegroundColor Yellow
Write-Host "Only the existing OpenMW native target is rebuilt (Jobs=$Jobs)." -ForegroundColor Yellow

try {
    & wsl.exe --exec bash $WslHelper
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $WindowsHelper -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $PatchSha)) {
    throw 'Patch 13 rebuild completed without writing the packaged JNI SHA marker.'
}

$ExpectedSha = ((Get-Content $PatchSha -Raw).Trim() -split '\s+')[0]
$ActualSha = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedSha.ToLowerInvariant() -ne $ActualSha) {
    throw "Patch 13 final SHA verification failed: expected=$ExpectedSha actual=$ActualSha"
}

Write-Host ''
Write-Host 'Patch 13 is ready for APK assembly.' -ForegroundColor Green
Write-Host "Packaged libopenmw.so SHA-256: $ActualSha" -ForegroundColor Green
Write-Host 'Expected Logcat markers:' -ForegroundColor Cyan
Write-Host '  OpenMW 0.51 Android Gate G PP init: <width>x<height>'
Write-Host '  OpenMW 0.51 Gate G runtime: shadows=false (test isolation), postProcessing=true, chain=adjustments, omwfx=false'
