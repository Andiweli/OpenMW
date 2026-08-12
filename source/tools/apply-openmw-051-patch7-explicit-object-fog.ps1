param(
    [ValidateRange(1, 32)]
    [int]$Jobs = 6,
    [switch]$PatchOnly
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
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

$Marker = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$StateUpdater = Join-Path $SourceRoot 'components\sceneutil\stateupdater.cpp'
$NifLoader = Join-Path $SourceRoot 'components\nifosg\nifloader.cpp'
$ObjectsFrag = Join-Path $SourceRoot 'files\shaders\compatibility\objects.frag'
$FogGlsl = Join-Path $SourceRoot 'files\shaders\compatibility\fog.glsl'
$AssetObjectsFrag = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\objects.frag'
$AssetFogGlsl = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\fog.glsl'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'

foreach ($Required in @($Marker, $RuntimePatcher, $SourceRoot, $BuildRoot, $StateUpdater, $NifLoader, $ObjectsFrag, $FogGlsl, $MainActivity, $JniLib)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 7 requires the existing successful OpenMW 0.51 Patch-6/Patch-5 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $Marker) -ne $ExpectedMarker) {
    throw 'Patch 7 refused a non-0.51-Final runtime payload.'
}

$PatcherText = Read-Lf $RuntimePatcher
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG_UNIFORMS') -or
    -not $PatcherText.Contains('OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG')) {
    throw 'Patch 7 package is incomplete: future-build explicit object-fog markers are missing from apply-android-runtime-baseline.py.'
}

$MainText = Read-Lf $MainActivity
if (-not $MainText.Contains('OpenMW 0.51 Patch 7 GL4ES core + explicit object fog shaders')) {
    throw 'Patch 7 package is incomplete: MainActivity does not sync the Patch-7 object/fog shaders.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch7-explicit-object-fog.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch7-explicit-object-fog.sh"

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
STATEUPDATER="$SOURCE/components/sceneutil/stateupdater.cpp"
NIFLOADER="$SOURCE/components/nifosg/nifloader.cpp"
OBJECTS="$SOURCE/files/shaders/compatibility/objects.frag"
FOG="$SOURCE/files/shaders/compatibility/fog.glsl"
ASSET_DIR="$PROJECT/app/src/main/assets/libopenmw/resources/shaders/compatibility"
ASSET_OBJECTS="$ASSET_DIR/objects.frag"
ASSET_FOG="$ASSET_DIR/fog.glsl"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
if [[ "$(cat "$MARKER")" != "$EXPECTED_MARKER" ]]; then
    echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2
    exit 20
fi
if [ ! -f "$SOURCE/CMakeLists.txt" ] || ! grep -Eq 'set\(OPENMW_VERSION_MINOR[[:space:]]+51\)' "$SOURCE/CMakeLists.txt"; then
    echo 'ERROR: extracted native source is not OpenMW 0.51.x.' >&2
    exit 21
fi

# The permanent runtime patcher now both retires Patch 6 and installs Patch 7.
python3 "$PATCHER" "$SOURCE"

if grep -Fq 'OPENMW_ANDROID_051_FOG_DIAG_INHERIT_DISABLED_NIF_FOG' "$NIFLOADER"; then
    echo 'ERROR: rejected Patch-6 NiFogProperty diagnostic is still active.' >&2
    exit 22
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG_UNIFORMS' "$STATEUPDATER"; then
    echo 'ERROR: explicit Android object-fog StateUpdater uniforms are missing.' >&2
    exit 23
fi
if ! grep -Fq '#define OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG' "$OBJECTS"; then
    echo 'ERROR: objects.frag does not enable the Patch-7 explicit fog path.' >&2
    exit 24
fi
if ! grep -Fq 'uniform float omwFogStart;' "$FOG" || ! grep -Fq 'uniform float omwFogEnd;' "$FOG" || ! grep -Fq 'uniform vec4 omwFogColor;' "$FOG"; then
    echo 'ERROR: fog.glsl explicit OpenMW fog uniforms are missing.' >&2
    exit 25
fi
if ! grep -Fq '#define OPENMW_FOG_START gl_Fog.start' "$FOG" || ! grep -Fq '#define OPENMW_FOG_COLOR gl_Fog.color' "$FOG"; then
    echo 'ERROR: fog.glsl no longer preserves the upstream gl_Fog fallback for non-object shaders.' >&2
    exit 26
fi

# Deploy the patched shader sources into the APK asset payload. MainActivity Patch 7
# refreshes these two files into both private and writable resource mirrors each launch.
mkdir -p "$ASSET_DIR"
cp -f "$OBJECTS" "$ASSET_OBJECTS"
cp -f "$FOG" "$ASSET_FOG"

if ! cmp -s "$OBJECTS" "$ASSET_OBJECTS" || ! cmp -s "$FOG" "$ASSET_FOG"; then
    echo 'ERROR: Patch-7 shader assets do not match native-source shaders.' >&2
    exit 27
fi

echo
echo 'OpenMW 0.51 Patch 7 source + shader payload: READY'
echo 'Patch 6 NiFogProperty diagnostic: REMOVED'
echo 'objects.frag: explicit authoritative fog uniforms ENABLED'
echo 'terrain/fog fallback: unchanged upstream gl_Fog path'

if [ "__PATCH_ONLY__" = "1" ]; then
    echo 'PatchOnly selected: native library was not rebuilt.'
    exit 0
fi

if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
    echo 'ERROR: pinned NDK llvm-strip/llvm-readelf is missing.' >&2
    exit 28
fi

echo
echo "Incrementally rebuilding OpenMW object-fog fix with parallelism=$JOBS ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
if [ "${#BUILT_LIBS[@]}" -eq 0 ]; then
    echo "ERROR: rebuilt libopenmw.so not found under $BUILD" >&2
    exit 29
fi
if [ "${#BUILT_LIBS[@]}" -gt 1 ]; then
    printf 'ERROR: multiple rebuilt libopenmw.so candidates found:\n' >&2
    printf '  %s\n' "${BUILT_LIBS[@]}" >&2
    exit 30
fi
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

if ! grep -aFq 'OpenMW 0.51.0' "$SYMBOLS" || ! grep -aFq 'OpenMW 0.51.0' "$JNI"; then
    echo 'ERROR: rebuilt library does not identify as OpenMW 0.51.0.' >&2
    exit 31
fi

SYMBOL_SIZE=$(stat -c %s "$SYMBOLS")
JNI_SIZE=$(stat -c %s "$JNI")
if [ "$JNI_SIZE" -ge "$SYMBOL_SIZE" ]; then
    echo "ERROR: packaged library was not stripped (packaged=$JNI_SIZE symbols=$SYMBOL_SIZE)." >&2
    exit 32
fi
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo 'ERROR: packaged libopenmw.so still contains DWARF debug sections.' >&2
    exit 33
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
SYMBOL_SHA=$(sha256sum "$SYMBOLS" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch7-libopenmw.sha256"

echo
echo 'OpenMW 0.51 Patch 7 explicit-object-fog native rebuild: SUCCESS'
printf 'Packaged/stripped lib: %s (%s bytes)\n' "$JNI" "$JNI_SIZE"
printf 'Symbol/unstripped lib: %s (%s bytes)\n' "$SYMBOLS" "$SYMBOL_SIZE"
printf 'Packaged SHA-256: %s\n' "$JNI_SHA"
printf 'Symbol SHA-256:   %s\n' "$SYMBOL_SHA"
echo 'Next: rebuild/reinstall the APK normally in Android Studio.'
'@

$ShellScript = $ShellScript.Replace('__PROJECT__', (Quote-Bash $WslProject))
$ShellScript = $ShellScript.Replace('__JOBS__', $Jobs.ToString())
$ShellScript = $ShellScript.Replace('__PATCH_ONLY__', $(if ($PatchOnly) { '1' } else { '0' }))
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsHelper, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 7 - explicit GL4ES object fog' -ForegroundColor Cyan
Write-Host 'Uses OpenMW StateUpdater fog color/start/end as normal uniforms for objects.frag only.' -ForegroundColor Cyan
Write-Host 'Patch 6 NiFogProperty diagnostic is removed/restored to upstream 0.51.' -ForegroundColor DarkGray
if (-not $PatchOnly) {
    Write-Host "Only the existing OpenMW native target will be incrementally rebuilt (Jobs=$Jobs)." -ForegroundColor Yellow
    Write-Host 'Third-party dependencies are NOT rebuilt.' -ForegroundColor DarkGray
}

try {
    & wsl.exe --exec bash $WslHelper
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $WindowsHelper -Force -ErrorAction SilentlyContinue
}

$StateText = Read-Lf $StateUpdater
$NifText = Read-Lf $NifLoader
$ObjectsText = Read-Lf $ObjectsFrag
$FogText = Read-Lf $FogGlsl
if ($NifText.Contains('OPENMW_ANDROID_051_FOG_DIAG_INHERIT_DISABLED_NIF_FOG')) {
    throw 'Patch 7 Windows-side verification failed: Patch-6 FogDiag marker remains.'
}
if (-not $StateText.Contains('OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG_UNIFORMS') -or
    -not $ObjectsText.Contains('OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG') -or
    -not $FogText.Contains('uniform float omwFogStart')) {
    throw 'Patch 7 Windows-side source verification failed.'
}
foreach ($Asset in @($AssetObjectsFrag, $AssetFogGlsl)) {
    if (-not (Test-Path $Asset)) { throw "Patch 7 shader asset verification failed: missing $Asset" }
}

if (-not $PatchOnly) {
    foreach ($Required in @($JniLib, $SymbolLib)) {
        if (-not (Test-Path $Required)) { throw "Patch 7 output verification failed: missing $Required" }
    }
    $JniSize = (Get-Item $JniLib).Length
    $SymbolSize = (Get-Item $SymbolLib).Length
    if ($JniSize -ge $SymbolSize) {
        throw "Patch 7 strip verification failed: packaged=$JniSize symbol=$SymbolSize"
    }
    Write-Host ''
    Write-Host 'Patch 7 is ready for APK assembly.' -ForegroundColor Green
    Write-Host "Packaged libopenmw.so: $JniLib ($JniSize bytes)"
    Write-Host "Unstripped symbols:    $SymbolLib ($SymbolSize bytes)"
    Write-Host "Packaged SHA-256:      $((Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant())"
}
