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

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Replace-Exact([string]$Path, [string]$Label, [string]$Old, [string]$New) {
    $Text = Read-Lf $Path
    if ($Text.Contains($New)) {
        Write-Host "$Label already applied."
        return
    }
    $Count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($Count -ne 1) {
        throw "${Label}: expected exactly one old block in $Path, found $Count"
    }
    Write-Utf8Lf $Path ($Text.Replace($Old, $New))
    Write-Host "Applied $Label."
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
$ShadowCpp = Join-Path $SourceRoot 'components\sceneutil\shadow.cpp'
$ShadowReceiver = Join-Path $SourceRoot 'files\shaders\compatibility\shadows_fragment.glsl'
$ShadowCaster = Join-Path $SourceRoot 'files\shaders\compatibility\shadowcasting.vert'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'

foreach ($Required in @($MarkerFile, $RuntimePatcher, $SourceRoot, $BuildRoot, $ShadowCpp, $ShadowReceiver, $ShadowCaster, $MainActivity, $JniLib)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 12c requires the working Patch-12b OpenMW 0.51 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit"
if ((Read-Lf $MarkerFile).Trim() -ne $ExpectedMarker) {
    throw 'Patch 12c refused a non-0.51-Final runtime payload.'
}

# Require the current, already-tested Patch-12b baseline before changing the projection.
$ReceiverText = Read-Lf $ShadowReceiver
$CasterText = Read-Lf $ShadowCaster
$ShadowText = Read-Lf $ShadowCpp
$PatcherText = Read-Lf $RuntimePatcher
foreach ($RequiredMarker in @(
    'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE',
    'OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS',
    'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING'
)) {
    if (-not (($ReceiverText + $CasterText + $ShadowText + $PatcherText).Contains($RequiredMarker))) {
        throw "Patch 12c baseline check failed: missing $RequiredMarker"
    }
}
if (-not $ReceiverText.Contains('OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS')) {
    throw 'Patch 12c requires Patch 12b shadow receiver bounds to be present.'
}

# ---------------------------------------------------------------------------
# Patch 12c: avoid the camera/light-angle-dependent LiSPSM path on Android.
# Keep one shadow map, resolution, distance, fade, receiver compare and caster
# path unchanged so this is a clean projection-only A/B test.
# ---------------------------------------------------------------------------
$ProjectionAnchor = '        mShadowSettings->setMultipleShadowMapHint(osgShadow::ShadowSettings::CASCADED);'
$ProjectionBlock = @'
        mShadowSettings->setMultipleShadowMapHint(osgShadow::ShadowSettings::CASCADED);
#ifdef ANDROID
        // OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP
        // GL4ES/GLES2 stability: avoid the view/light-angle-dependent LiSPSM
        // perspective projection. Preserve the existing single map, distance,
        // resolution and fade settings; only the shadow projection changes.
        mShadowSettings->setShadowMapProjectionHint(osgShadow::ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP);
#endif
'@.TrimEnd([char[]]"`r`n")
Replace-Exact $ShadowCpp 'Patch 12c Android orthographic shadow projection' $ProjectionAnchor $ProjectionBlock

# Permanently teach clean 0.51 native builds to reproduce the same projection.
$PatcherAnchor = '# Final structural verification.'
$PatcherProjectionBlock = @'
# ---------------------------------------------------------------------------
# Patch 12c: Android orthographic shadow projection.
# OpenMW 0.51 defaults to the camera/light-angle-dependent LiSPSM perspective
# path. On GL4ES/GLES2 keep the already proven one-map configuration but avoid
# that projection path; this also makes perspectiveShadowMaps=0 naturally.
# ---------------------------------------------------------------------------
projection_marker = 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP'
text = shadow_manager.read_text(encoding='utf-8')
if projection_marker not in text:
    text = replace_once(
        text,
        '        mShadowSettings->setMultipleShadowMapHint(osgShadow::ShadowSettings::CASCADED);\n',
        '''        mShadowSettings->setMultipleShadowMapHint(osgShadow::ShadowSettings::CASCADED);
#ifdef ANDROID
        // OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP
        // GL4ES/GLES2 stability: avoid the view/light-angle-dependent LiSPSM
        // perspective projection. Preserve the existing single map, distance,
        // resolution and fade settings; only the shadow projection changes.
        mShadowSettings->setShadowMapProjectionHint(osgShadow::ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP);
#endif
''',
        'shadow.cpp/Android orthographic shadow projection',
    )
    shadow_manager.write_text(text, encoding='utf-8', newline='\n')
    print('Forced orthographic shadow projection on Android/GL4ES.')
else:
    print('Android orthographic shadow projection is already applied.')

# Final structural verification.
'@.TrimEnd([char[]]"`r`n")
Replace-Exact $RuntimePatcher 'Patch 12c permanent runtime patcher projection block' $PatcherAnchor $PatcherProjectionBlock

$OldVerifyTuple = @'
    (shadow_compare_marker, shadow_manager_text),
    (depth_clamp_marker, shadow_casting_text),
'@.TrimEnd([char[]]"`r`n")
$NewVerifyTuple = @'
    (shadow_compare_marker, shadow_manager_text),
    ('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP', shadow_manager_text),
    (depth_clamp_marker, shadow_casting_text),
'@.TrimEnd([char[]]"`r`n")
Replace-Exact $RuntimePatcher 'Patch 12c permanent runtime patcher verification marker' $OldVerifyTuple $NewVerifyTuple

# Make Logcat identify the new gate without changing launcher behaviour.
$MainText = Read-Lf $MainActivity
$MainText = $MainText.Replace(
    'Synced OpenMW 0.51 Patch 12b bounded GLES2 shadows + GL4ES compatibility; post processing remains disabled',
    'Synced OpenMW 0.51 Patch 12c orthographic GLES2 shadows + GL4ES compatibility; post processing remains disabled'
)
$MainText = $MainText.Replace(
    'OpenMW 0.51 Patch 12b runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false',
    'OpenMW 0.51 Patch 12c runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false'
)
Write-Utf8Lf $MainActivity $MainText

# Source-side verification before spending time on the native link.
$ShadowText = Read-Lf $ShadowCpp
$PatcherText = Read-Lf $RuntimePatcher
if (-not $ShadowText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP') -or
    -not $ShadowText.Contains('setShadowMapProjectionHint(osgShadow::ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP)')) {
    throw 'Patch 12c source verification failed: orthographic projection is incomplete.'
}
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP')) {
    throw 'Patch 12c permanent patcher verification failed.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch12c-orthographic-shadows.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch12c-orthographic-shadows.sh"

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
SHADOW_CPP="$SOURCE/components/sceneutil/shadow.cpp"
SHADOW_FRAG="$SOURCE/files/shaders/compatibility/shadows_fragment.glsl"
SHADOW_CAST="$SOURCE/files/shaders/compatibility/shadowcasting.vert"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
if [[ "$(cat "$MARKER")" != "$EXPECTED_MARKER" ]]; then
    echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2
    exit 20
fi
if [ ! -f "$SOURCE/CMakeLists.txt" ] || ! grep -Eq 'set\(OPENMW_VERSION_MINOR[[:space:]]+51\)' "$SOURCE/CMakeLists.txt"; then
    echo 'ERROR: extracted native source is not OpenMW 0.51.x.' >&2
    exit 21
fi

# Re-run the permanent semantic baseline as an idempotency/clean-build check.
python3 "$PATCHER" "$SOURCE"

if ! grep -Fq 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP' "$SHADOW_CPP" || \
   ! grep -Fq 'setShadowMapProjectionHint(osgShadow::ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP)' "$SHADOW_CPP"; then
    echo 'ERROR: Android orthographic shadow projection is missing.' >&2
    exit 22
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS' "$SHADOW_FRAG"; then
    echo 'ERROR: Patch-12b receiver bounds were lost.' >&2
    exit 23
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' "$SHADOW_CAST"; then
    echo 'ERROR: Patch-12d native shadow clipping marker was lost.' >&2
    exit 24
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_FRAG"; then
    echo 'ERROR: GLES2 manual shadow comparison was lost.' >&2
    exit 25
fi
if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
    echo 'ERROR: pinned NDK llvm-strip/llvm-readelf is missing.' >&2
    exit 26
fi

echo
echo 'OpenMW 0.51 Patch 12c source: READY'
echo '  Android shadow projection: ORTHOGRAPHIC (LiSPSM perspective path bypassed)'
echo '  Shadow maps: still exactly 1'
echo '  Quality / distance / fade: unchanged from Patch 12'
echo '  Patch-12b receiver bounds: retained'
echo '  Post Processing / OMWFX: still forced OFF'
echo
echo "Incrementally rebuilding OpenMW only (parallelism=$JOBS) ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
if [ "${#BUILT_LIBS[@]}" -eq 0 ]; then
    echo "ERROR: rebuilt libopenmw.so not found under $BUILD" >&2
    exit 27
fi
if [ "${#BUILT_LIBS[@]}" -gt 1 ]; then
    printf 'ERROR: multiple rebuilt libopenmw.so candidates found:\n' >&2
    printf '  %s\n' "${BUILT_LIBS[@]}" >&2
    exit 28
fi
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

if ! grep -aFq 'OpenMW 0.51.0' "$SYMBOLS" || ! grep -aFq 'OpenMW 0.51.0' "$JNI"; then
    echo 'ERROR: rebuilt library does not identify as OpenMW 0.51.0.' >&2
    exit 29
fi
if ! grep -aFq 'Android GLES2 manual shadow comparison enabled' "$SYMBOLS"; then
    echo 'ERROR: rebuilt library lost the Patch-12 shadow receiver compatibility path.' >&2
    exit 30
fi

SYMBOL_SIZE=$(stat -c %s "$SYMBOLS")
JNI_SIZE=$(stat -c %s "$JNI")
if [ "$JNI_SIZE" -ge "$SYMBOL_SIZE" ]; then
    echo "ERROR: packaged library was not stripped (packaged=$JNI_SIZE symbols=$SYMBOL_SIZE)." >&2
    exit 31
fi
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo 'ERROR: packaged libopenmw.so still contains DWARF debug sections.' >&2
    exit 32
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
SYMBOL_SHA=$(sha256sum "$SYMBOLS" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch12c-libopenmw.sha256"

echo
echo 'OpenMW 0.51 Patch 12c orthographic-shadow native rebuild: SUCCESS'
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
Write-Host 'OpenMW 0.51 Patch 12c - Android Orthographic Shadows' -ForegroundColor Cyan
Write-Host 'A/B test: bypasses 0.51 LiSPSM perspective projection on GL4ES/GLES2.' -ForegroundColor Cyan
Write-Host 'One shadow map, quality, distance, fade and manual depth compare remain unchanged.' -ForegroundColor Yellow
Write-Host "Only the existing OpenMW native target is rebuilt (Jobs=$Jobs)." -ForegroundColor Yellow
Write-Host 'Post Processing / OMWFX remain OFF.' -ForegroundColor DarkGray

try {
    & wsl.exe --exec bash $WslHelper
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $WindowsHelper -Force -ErrorAction SilentlyContinue
}

# Windows-side final verification.
$ShadowText = Read-Lf $ShadowCpp
$PatcherText = Read-Lf $RuntimePatcher
$MainText = Read-Lf $MainActivity
if (-not $ShadowText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP') -or
    -not $ShadowText.Contains('ORTHOGRAPHIC_SHADOW_MAP')) {
    throw 'Patch 12c final source verification failed.'
}
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP')) {
    throw 'Patch 12c final permanent-patcher verification failed.'
}
if (-not $MainText.Contains('Patch 12c orthographic GLES2 shadows')) {
    throw 'Patch 12c Logcat marker update failed.'
}
if (-not (Test-Path $SymbolLib)) {
    throw 'Patch 12c symbol library is missing after rebuild.'
}
$JniSize = (Get-Item $JniLib).Length
$SymbolSize = (Get-Item $SymbolLib).Length
if ($JniSize -ge $SymbolSize) {
    throw "Patch 12c strip verification failed: packaged=$JniSize symbols=$SymbolSize"
}

Write-Host ''
Write-Host 'Patch 12c is ready for APK assembly.' -ForegroundColor Green
Write-Host "Packaged SHA-256: $((Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host 'Device test: Shadows ON / Medium / Medium. Test Match Sunlight to sun both ON and OFF.' -ForegroundColor Cyan
