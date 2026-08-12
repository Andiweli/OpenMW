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
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$MwShadowTechnique = Join-Path $SourceRoot 'components\sceneutil\mwshadowtechnique.cpp'
$ShadowCpp = Join-Path $SourceRoot 'components\sceneutil\shadow.cpp'
$ShadowReceiver = Join-Path $SourceRoot 'files\shaders\compatibility\shadows_fragment.glsl'
$ShadowCaster = Join-Path $SourceRoot 'files\shaders\compatibility\shadowcasting.vert'
$ShadowsBinHpp = Join-Path $SourceRoot 'components\sceneutil\shadowsbin.hpp'
$ShadowsBinCpp = Join-Path $SourceRoot 'components\sceneutil\shadowsbin.cpp'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'

foreach ($Required in @($MarkerFile, $JniLib, $SourceRoot, $BuildRoot, $MwShadowTechnique, $ShadowCpp, $ShadowReceiver, $ShadowCaster, $ShadowsBinHpp, $ShadowsBinCpp, $RuntimePatcher, $MainActivity)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 12j requires the working Patch-12i OpenMW 0.51 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit"
if ((Read-Lf $MarkerFile).Trim() -ne $ExpectedMarker) {
    throw 'Patch 12j refused a non-0.51-Final runtime payload.'
}

$MwShadowText = Read-Lf $MwShadowTechnique
$ShadowCppText = Read-Lf $ShadowCpp
$ReceiverText = Read-Lf $ShadowReceiver
$CasterText = Read-Lf $ShadowCaster
$ShadowsBinHppText = Read-Lf $ShadowsBinHpp
$ShadowsBinCppText = Read-Lf $ShadowsBinCpp

foreach ($Marker in @(
    'OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS',
    'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP',
    'OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING',
    'OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME'
)) {
    if (-not $MwShadowText.Contains($Marker)) {
        throw "Patch 12j requires Patch 12i baseline marker: $Marker"
    }
}
if (-not $ShadowCppText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP')) {
    throw 'Patch 12j requires Patch 12c orthographic shadows.'
}
if (-not $CasterText.Contains('OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING')) {
    throw 'Patch 12j requires Patch 12d native GLES2 shadow clipping.'
}
if (-not $ReceiverText.Contains('OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE') -or
    -not $ReceiverText.Contains('OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS')) {
    throw 'Patch 12j requires the Patch-12/12b GLES2 receiver baseline.'
}
if (-not $ShadowsBinHppText.Contains('OPENMW_ANDROID_051_SHADOW_GL_DIAG') -or
    -not $ShadowsBinCppText.Contains('OPENMW_SHADOW_GL_DIAG Patch 12f active')) {
    throw 'Patch 12j expects Patch 12f diagnostics to remain present.'
}

# IMPORTANT: OpenMW setupShadowSettings() uses CASCADED unconditionally, even
# for one map. Patch 12g bypassed only the else/non-CASCADED branch. Replace
# that flawed block with an all-path bypass so the 12i fixed projection really
# stays fixed when the main camera rotates.
$OldFlawedCropBlock = @'
            if (settings->getMultipleShadowMapHint() == ShadowSettings::CASCADED)
            {
                cropShadowCameraToMainFrustum(frustum, camera, cascaseNear, cascadeFar, extraPlanes);
                for (const auto& plane : extraPlanes)
                    local_polytope.getPlaneList().push_back(plane);
                local_polytope.setupMask();
            }
            else
            {
#ifdef ANDROID
                if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
                    && pl.directionalLight)
                {
                    // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP
                    // Diagnostic A/B: keep the already-computed orthographic
                    // light-space projection intact instead of re-cropping it
                    // to the current main-camera frustum. This removes one
                    // remaining view-dependent shadow-camera transform while
                    // leaving ComputeLightSpaceBounds tightening untouched.
                }
                else
#endif
                    cropShadowCameraToMainFrustum(frustum, camera, reducedNear, reducedFar, extraPlanes);
            }
'@.TrimEnd([char[]]"`r`n")

$NewCorrectedCropBlock = @'
            bool bypassMainFrustumCrop = false;
#ifdef ANDROID
            if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
                && pl.directionalLight)
            {
                // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP
                // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS
                // Patch 12j correction: setupShadowSettings() uses CASCADED
                // even with exactly one shadow map, so the previous Patch 12g
                // else-only bypass never affected our active path.
                bypassMainFrustumCrop = true;
            }
#endif
            if (!bypassMainFrustumCrop)
            {
                if (settings->getMultipleShadowMapHint() == ShadowSettings::CASCADED)
                {
                    cropShadowCameraToMainFrustum(frustum, camera, cascaseNear, cascadeFar, extraPlanes);
                    for (const auto& plane : extraPlanes)
                        local_polytope.getPlaneList().push_back(plane);
                    local_polytope.setupMask();
                }
                else
                    cropShadowCameraToMainFrustum(frustum, camera, reducedNear, reducedFar, extraPlanes);
            }
'@.TrimEnd([char[]]"`r`n")

Replace-Exact $MwShadowTechnique 'Patch 12j corrected all-path main-frustum crop bypass' $OldFlawedCropBlock $NewCorrectedCropBlock

# Make the clean-source runtime patcher correct the earlier 12g semantic edit
# after it is applied. A new marker prevents the old marker from falsely
# reporting that the all-path correction is present.
$Patcher = Read-Lf $RuntimePatcher
$NewMarker = 'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS'
if (-not $Patcher.Contains($NewMarker)) {
    $Anchor = '# Final structural verification.'
    $Count = ([regex]::Matches($Patcher, [regex]::Escape($Anchor))).Count
    if ($Count -ne 1) {
        throw "Patch 12j permanent patcher: expected one final-verification anchor, found $Count"
    }

    $CorrectionBlock = @'
# ---------------------------------------------------------------------------
# Patch 12j: correct Patch 12g for the actually active CASCADED one-map path.
# setupShadowSettings() sets CASCADED unconditionally, so bypass the final
# main-frustum crop for Android orthographic directional shadows regardless of
# the multiple-shadow-map hint.
# ---------------------------------------------------------------------------
all_path_crop_bypass_marker = 'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS'
text = mwshadowtechnique.read_text(encoding='utf-8')
if all_path_crop_bypass_marker not in text:
    text = replace_once(
        text,
        '''            if (settings->getMultipleShadowMapHint() == ShadowSettings::CASCADED)
            {
                cropShadowCameraToMainFrustum(frustum, camera, cascaseNear, cascadeFar, extraPlanes);
                for (const auto& plane : extraPlanes)
                    local_polytope.getPlaneList().push_back(plane);
                local_polytope.setupMask();
            }
            else
            {
#ifdef ANDROID
                if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
                    && pl.directionalLight)
                {
                    // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP
                    // Diagnostic A/B: keep the already-computed orthographic
                    // light-space projection intact instead of re-cropping it
                    // to the current main-camera frustum. This removes one
                    // remaining view-dependent shadow-camera transform while
                    // leaving ComputeLightSpaceBounds tightening untouched.
                }
                else
#endif
                    cropShadowCameraToMainFrustum(frustum, camera, reducedNear, reducedFar, extraPlanes);
            }
''',
        '''            bool bypassMainFrustumCrop = false;
#ifdef ANDROID
            if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
                && pl.directionalLight)
            {
                // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP
                // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS
                // Patch 12j correction: setupShadowSettings() uses CASCADED
                // even with exactly one shadow map, so the previous Patch 12g
                // else-only bypass never affected our active path.
                bypassMainFrustumCrop = true;
            }
#endif
            if (!bypassMainFrustumCrop)
            {
                if (settings->getMultipleShadowMapHint() == ShadowSettings::CASCADED)
                {
                    cropShadowCameraToMainFrustum(frustum, camera, cascaseNear, cascadeFar, extraPlanes);
                    for (const auto& plane : extraPlanes)
                        local_polytope.getPlaneList().push_back(plane);
                    local_polytope.setupMask();
                }
                else
                    cropShadowCameraToMainFrustum(frustum, camera, reducedNear, reducedFar, extraPlanes);
            }
''',
        'mwshadowtechnique.cpp/Android all-path no-main-frustum-crop correction',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Corrected Android orthographic main-frustum crop bypass for CASCADED one-map path.')
else:
    print('Android all-path main-frustum crop bypass correction is already applied.')

# Final structural verification.
'@.TrimEnd([char[]]"`r`n")

    $Patcher = $Patcher.Replace($Anchor, $CorrectionBlock)

    $ReadyPrint = "print('OpenMW 0.51 Android runtime baseline patch: READY')"
    $ReadyCount = ([regex]::Matches($Patcher, [regex]::Escape($ReadyPrint))).Count
    if ($ReadyCount -ne 1) {
        throw "Patch 12j permanent verification: expected one READY print, found $ReadyCount"
    }
    $Verify = @'
if 'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS' not in mwshadowtechnique.read_text(encoding='utf-8'):
    raise SystemExit('OpenMW 0.51 Android all-path main-frustum-crop bypass correction is missing')

print('OpenMW 0.51 Android runtime baseline patch: READY')
'@.TrimEnd([char[]]"`r`n")
    $Patcher = $Patcher.Replace($ReadyPrint, $Verify)
    Write-Utf8Lf $RuntimePatcher $Patcher
}

# Identify the diagnostic APK in Logcat.
$Main = Read-Lf $MainActivity
$Main = $Main.Replace(
    'Synced OpenMW 0.51 Patch 12i fixed-eye-volume GLES2 shadows over Patch 12h; post processing remains disabled',
    'Synced OpenMW 0.51 Patch 12j corrected all-path frustum-crop bypass over Patch 12i; post processing remains disabled'
)
$Main = $Main.Replace(
    'OpenMW 0.51 Patch 12i runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false',
    'OpenMW 0.51 Patch 12j runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false'
)
Write-Utf8Lf $MainActivity $Main

# Pre-build verification.
$MwShadowText = Read-Lf $MwShadowTechnique
$PatcherText = Read-Lf $RuntimePatcher
$MainText = Read-Lf $MainActivity
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS')) {
    throw 'Patch 12j source verification failed: corrected all-path crop marker missing.'
}
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME')) {
    throw 'Patch 12j source verification failed: Patch 12i fixed eye volume was lost.'
}
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING')) {
    throw 'Patch 12j source verification failed: Patch 12h caster-bounds bypass was lost.'
}
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS')) {
    throw 'Patch 12j permanent patcher verification failed.'
}
if (-not $MainText.Contains('Patch 12j corrected all-path frustum-crop bypass over Patch 12i')) {
    throw 'Patch 12j Logcat marker update failed.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch12j-correct-frustum-crop-bypass.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch12j-correct-frustum-crop-bypass.sh"

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
MWST="$SOURCE/components/sceneutil/mwshadowtechnique.cpp"
SHADOW_CPP="$SOURCE/components/sceneutil/shadow.cpp"
SHADOW_FRAG="$SOURCE/files/shaders/compatibility/shadows_fragment.glsl"
SHADOW_CAST="$SOURCE/files/shaders/compatibility/shadowcasting.vert"
SHADOWS_BIN_HPP="$SOURCE/components/sceneutil/shadowsbin.hpp"
SHADOWS_BIN_CPP="$SOURCE/components/sceneutil/shadowsbin.cpp"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
if [[ "$(cat "$MARKER")" != "$EXPECTED_MARKER" ]]; then
    echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2
    exit 20
fi

python3 "$PATCHER" "$SOURCE"

for marker in \
    OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP \
    OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS \
    OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING \
    OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME \
    OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS; do
    if ! grep -Fq "$marker" "$MWST"; then
        echo "ERROR: missing mwshadowtechnique marker: $marker" >&2
        exit 21
    fi
done
if ! grep -Fq 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP' "$SHADOW_CPP"; then
    echo 'ERROR: Patch-12c orthographic shadow map was lost.' >&2
    exit 22
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' "$SHADOW_CAST"; then
    echo 'ERROR: Patch-12d native clipping was lost.' >&2
    exit 23
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_FRAG" || \
   ! grep -Fq 'OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS' "$SHADOW_FRAG"; then
    echo 'ERROR: Patch-12/12b receiver baseline was lost.' >&2
    exit 24
fi
if ! grep -Fq 'OPENMW_ANDROID_051_SHADOW_GL_DIAG' "$SHADOWS_BIN_HPP" || \
   ! grep -Fq 'OPENMW_SHADOW_GL_DIAG Patch 12f active' "$SHADOWS_BIN_CPP"; then
    echo 'ERROR: Patch-12f diagnostics were lost.' >&2
    exit 25
fi
if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
    echo 'ERROR: pinned NDK tools are missing.' >&2
    exit 26
fi

echo
echo 'OpenMW 0.51 Patch 12j source: READY'
echo '  Exactly 1 shadow map; projection remains ORTHOGRAPHIC'
echo '  Patch 12i fixed eye volume remains active'
echo '  Main-frustum crop: REALLY DISABLED for CASCADED + non-CASCADED Android ortho directional path'
echo '  Caster-bounds tightening remains disabled'
echo '  Custom light-frustum caster polytope remains active (next A/B only if needed)'
echo '  Patch 12f GL probes remain active'
echo '  Post Processing / OMWFX remain OFF'
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
if ! grep -aFq 'OPENMW_SHADOW_GL_DIAG Patch 12f active' "$SYMBOLS"; then
    echo 'ERROR: rebuilt library lost Patch-12f diagnostic marker.' >&2
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
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch12j-libopenmw.sha256"

echo
echo 'OpenMW 0.51 Patch 12j corrected-frustum-crop native rebuild: SUCCESS'
printf 'Packaged/stripped lib: %s (%s bytes)\n' "$JNI" "$JNI_SIZE"
printf 'Symbol/unstripped lib: %s (%s bytes)\n' "$SYMBOLS" "$SYMBOL_SIZE"
printf 'Packaged SHA-256: %s\n' "$JNI_SHA"
printf 'Symbol SHA-256:   %s\n' "$SYMBOL_SHA"
echo 'Next: rebuild/reinstall APK and retest the same Vivec camera angles.'
'@

$ShellScript = $ShellScript.Replace('__PROJECT__', (Quote-Bash $WslProject))
$ShellScript = $ShellScript.Replace('__JOBS__', $Jobs.ToString())
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsHelper, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 12j - Corrected All-Path Frustum Crop Bypass' -ForegroundColor Cyan
Write-Host 'Important: Patch 12g did NOT hit the active CASCADED one-map branch. Patch 12j corrects that.' -ForegroundColor Yellow
Write-Host "Only the existing OpenMW native target is rebuilt (Jobs=$Jobs)." -ForegroundColor Yellow
Write-Host 'Post Processing / OMWFX remain OFF.' -ForegroundColor DarkGray

try {
    & wsl.exe --exec bash $WslHelper
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $WindowsHelper -Force -ErrorAction SilentlyContinue
}

$MwShadowText = Read-Lf $MwShadowTechnique
$MainText = Read-Lf $MainActivity
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS')) {
    throw 'Patch 12j final source verification failed.'
}
if (-not $MainText.Contains('Patch 12j corrected all-path frustum-crop bypass over Patch 12i')) {
    throw 'Patch 12j final Logcat marker verification failed.'
}
if (-not (Test-Path $SymbolLib)) {
    throw 'Patch 12j symbol library is missing after rebuild.'
}
$JniSize = (Get-Item $JniLib).Length
$SymbolSize = (Get-Item $SymbolLib).Length
if ($JniSize -ge $SymbolSize) {
    throw "Patch 12j strip verification failed: packaged=$JniSize symbols=$SymbolSize"
}

Write-Host ''
Write-Host 'Patch 12j is ready for APK assembly.' -ForegroundColor Green
Write-Host "Packaged SHA-256: $((Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host 'Retest the exact view angles/under-building cases. Match Sunlight may be ON or OFF.' -ForegroundColor Cyan
