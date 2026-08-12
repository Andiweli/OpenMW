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
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'

foreach ($Required in @($MarkerFile, $RuntimePatcher, $SourceRoot, $BuildRoot, $MainActivity, $JniLib)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 12 requires the saved successful Patch-11 OpenMW 0.51 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $MarkerFile) -ne $ExpectedMarker) {
    throw 'Patch 12 refused a non-0.51-Final runtime payload.'
}

$MainText = Read-Lf $MainActivity
if (-not $MainText.Contains('OpenMW 0.51 Patch 12 runtime gate: shadows=launcher-controlled')) {
    throw 'Patch 12 package is incomplete or was not overlaid correctly: MainActivity Patch-12 gate marker missing.'
}
if (-not $MainText.Contains('OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE')) {
    throw 'Patch 12 package is incomplete: MainActivity does not validate the GLES2 shadow receiver.'
}

$PatcherText = Read-Lf $RuntimePatcher
foreach ($RequiredMarker in @(
    'OPENMW_ANDROID_051_GL4ES_DISABLE_ADDITIVE_FOG',
    'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE',
    'OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK'
)) {
    if (-not $PatcherText.Contains($RequiredMarker)) {
        throw "Patch 12 permanent runtime patcher is missing marker: $RequiredMarker"
    }
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch12-shadows.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch12-shadows.sh"

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

SHADOW_FRAG="$SOURCE/files/shaders/compatibility/shadows_fragment.glsl"
SHADOW_CAST="$SOURCE/files/shaders/compatibility/shadowcasting.vert"
OBJECTS_FRAG="$SOURCE/files/shaders/compatibility/objects.frag"
MWTECH="$SOURCE/components/sceneutil/mwshadowtechnique.cpp"
SHADOW_CPP="$SOURCE/components/sceneutil/shadow.cpp"
ASSET_COMPAT="$PROJECT/app/src/main/assets/libopenmw/resources/shaders/compatibility"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
if [[ "$(cat "$MARKER")" != "$EXPECTED_MARKER" ]]; then
    echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2
    exit 20
fi
if [ ! -f "$SOURCE/CMakeLists.txt" ] || ! grep -Eq 'set\(OPENMW_VERSION_MINOR[[:space:]]+51\)' "$SOURCE/CMakeLists.txt"; then
    echo 'ERROR: extracted native source is not OpenMW 0.51.x.' >&2
    exit 21
fi

# Consolidated baseline now permanently preserves Patch 8 + proven Patch 11
# and installs the GLES2 shadow compatibility path.
python3 "$PATCHER" "$SOURCE"

if ! grep -Fq 'OPENMW_ANDROID_051_GL4ES_DISABLE_ADDITIVE_FOG' "$OBJECTS_FRAG" || grep -Fq '#define ADDITIVE_BLENDING' "$OBJECTS_FRAG"; then
    echo 'ERROR: proven Patch-11 additive-fog fix was not preserved.' >&2
    exit 22
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_FRAG"; then
    echo 'ERROR: manual shadow receiver marker missing.' >&2
    exit 23
fi
if grep -Fq 'uniform sampler2DShadow' "$SHADOW_FRAG" || grep -Fq 'shadow2DProj(' "$SHADOW_FRAG"; then
    echo 'ERROR: shadow receiver still contains unsupported desktop shadow-sampler syntax.' >&2
    exit 24
fi
if ! grep -Fq 'uniform sampler2D shadowTexture@shadow_texture_unit_index;' "$SHADOW_FRAG" || ! grep -Fq 'step(shadowXYZ.z, texture2D(' "$SHADOW_FRAG"; then
    echo 'ERROR: explicit GLES2 shadow depth comparison is incomplete.' >&2
    exit 25
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK' "$SHADOW_CAST" || ! grep -Fq 'gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);' "$SHADOW_CAST"; then
    echo 'ERROR: shadow-caster depth-clamp fallback missing.' >&2
    exit 26
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$MWTECH" || ! grep -Fq 'OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK' "$MWTECH"; then
    echo 'ERROR: MWShadowTechnique Android compatibility markers missing.' >&2
    exit 27
fi
if grep -Fq 'sampler2DShadow' "$MWTECH" || grep -Fq 'shadow2DProj(' "$MWTECH"; then
    echo 'ERROR: MWShadowTechnique fallback shaders still contain shadow-sampler syntax.' >&2
    exit 28
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_CPP"; then
    echo 'ERROR: GLES2-safe fake shadow texture fallback missing.' >&2
    exit 29
fi

# Deploy the two runtime shadow shaders. MainActivity Patch 12 refreshes these
# into both resource mirrors on every launch.
mkdir -p "$ASSET_COMPAT"
cp -f "$SHADOW_FRAG" "$ASSET_COMPAT/shadows_fragment.glsl"
cp -f "$SHADOW_CAST" "$ASSET_COMPAT/shadowcasting.vert"

if ! cmp -s "$SHADOW_FRAG" "$ASSET_COMPAT/shadows_fragment.glsl" || ! cmp -s "$SHADOW_CAST" "$ASSET_COMPAT/shadowcasting.vert"; then
    echo 'ERROR: Patch-12 shadow assets do not match the patched native source.' >&2
    exit 30
fi

if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
    echo 'ERROR: pinned NDK llvm-strip/llvm-readelf is missing.' >&2
    exit 31
fi

echo
echo 'OpenMW 0.51 Patch 12 source + shadow payload: READY'
echo '  Shadow maps: launcher hard-locks Android to exactly 1 map'
echo '  Quality: Low=1024, Medium=2048, High=4096'
echo '  Distance: Low=2048, Medium=4096, High=8192'
echo '  Fade start: 0.75 (outer 25% fades smoothly)'
echo '  Post Processing / OMWFX: still forced OFF'
echo
echo "Incrementally rebuilding OpenMW shadow compatibility with parallelism=$JOBS ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
if [ "${#BUILT_LIBS[@]}" -eq 0 ]; then
    echo "ERROR: rebuilt libopenmw.so not found under $BUILD" >&2
    exit 32
fi
if [ "${#BUILT_LIBS[@]}" -gt 1 ]; then
    printf 'ERROR: multiple rebuilt libopenmw.so candidates found:\n' >&2
    printf '  %s\n' "${BUILT_LIBS[@]}" >&2
    exit 33
fi
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

if ! grep -aFq 'OpenMW 0.51.0' "$SYMBOLS" || ! grep -aFq 'OpenMW 0.51.0' "$JNI"; then
    echo 'ERROR: rebuilt library does not identify as OpenMW 0.51.0.' >&2
    exit 34
fi
if ! grep -aFq 'Android GLES2 manual shadow comparison enabled' "$SYMBOLS"; then
    echo 'ERROR: rebuilt library does not contain the Patch-12 shadow compatibility marker string.' >&2
    exit 35
fi

SYMBOL_SIZE=$(stat -c %s "$SYMBOLS")
JNI_SIZE=$(stat -c %s "$JNI")
if [ "$JNI_SIZE" -ge "$SYMBOL_SIZE" ]; then
    echo "ERROR: packaged library was not stripped (packaged=$JNI_SIZE symbols=$SYMBOL_SIZE)." >&2
    exit 36
fi
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo 'ERROR: packaged libopenmw.so still contains DWARF debug sections.' >&2
    exit 37
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
SYMBOL_SHA=$(sha256sum "$SYMBOLS" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch12-libopenmw.sha256"

echo
echo 'OpenMW 0.51 Patch 12 shadow native rebuild: SUCCESS'
printf 'Packaged/stripped lib: %s (%s bytes)\n' "$JNI" "$JNI_SIZE"
printf 'Symbol/unstripped lib: %s (%s bytes)\n' "$SYMBOLS" "$SYMBOL_SIZE"
printf 'Packaged SHA-256: %s\n' "$JNI_SHA"
printf 'Symbol SHA-256:   %s\n' "$SYMBOL_SHA"
echo 'Next: rebuild/reinstall the APK normally in Android Studio.'
'@

$ShellScript = $ShellScript.Replace('__PROJECT__', (Quote-Bash $WslProject))
$ShellScript = $ShellScript.Replace('__JOBS__', $Jobs.ToString())
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsHelper, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 12 - Gate F / GLES2 Shadows' -ForegroundColor Cyan
Write-Host 'Preserves the confirmed Patch-11 rendering baseline and enables launcher-controlled shadows.' -ForegroundColor Cyan
Write-Host 'Exactly one shadow map is retained for Android stability.' -ForegroundColor Yellow
Write-Host "Only the existing OpenMW native target will be incrementally rebuilt (Jobs=$Jobs)." -ForegroundColor Yellow
Write-Host 'Third-party dependencies are NOT rebuilt. Post Processing/OMWFX remain OFF.' -ForegroundColor DarkGray

try {
    & wsl.exe --exec bash $WslHelper
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $WindowsHelper -Force -ErrorAction SilentlyContinue
}

$ShadowFrag = Join-Path $SourceRoot 'files\shaders\compatibility\shadows_fragment.glsl'
$ShadowCast = Join-Path $SourceRoot 'files\shaders\compatibility\shadowcasting.vert'
$MwTech = Join-Path $SourceRoot 'components\sceneutil\mwshadowtechnique.cpp'
$ShadowCpp = Join-Path $SourceRoot 'components\sceneutil\shadow.cpp'
$AssetShadowFrag = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\shadows_fragment.glsl'
$AssetShadowCast = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\shadowcasting.vert'

foreach ($Required in @($ShadowFrag, $ShadowCast, $MwTech, $ShadowCpp, $AssetShadowFrag, $AssetShadowCast, $JniLib, $SymbolLib)) {
    if (-not (Test-Path $Required)) { throw "Patch 12 output verification failed: missing $Required" }
}

$Receiver = Read-Lf $ShadowFrag
$Caster = Read-Lf $ShadowCast
if (-not $Receiver.Contains('OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE') -or
    $Receiver.Contains('uniform sampler2DShadow') -or $Receiver.Contains('shadow2DProj(')) {
    throw 'Patch 12 Windows-side shadow receiver verification failed.'
}
if (-not $Caster.Contains('OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK')) {
    throw 'Patch 12 Windows-side shadow caster verification failed.'
}
if ((Read-Lf $AssetShadowFrag) -ne $Receiver -or (Read-Lf $AssetShadowCast) -ne $Caster) {
    throw 'Patch 12 APK shadow asset verification failed.'
}

$JniSize = (Get-Item $JniLib).Length
$SymbolSize = (Get-Item $SymbolLib).Length
if ($JniSize -ge $SymbolSize) {
    throw "Patch 12 strip verification failed: packaged=$JniSize symbol=$SymbolSize"
}

Write-Host ''
Write-Host 'Patch 12 is ready for APK assembly.' -ForegroundColor Green
Write-Host "Packaged libopenmw.so: $JniLib ($JniSize bytes)"
Write-Host "Unstripped symbols:    $SymbolLib ($SymbolSize bytes)"
Write-Host "Packaged SHA-256:      $((Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host ''
Write-Host 'Recommended first device test: Shadows ON, Medium quality, Medium distance.' -ForegroundColor Cyan
