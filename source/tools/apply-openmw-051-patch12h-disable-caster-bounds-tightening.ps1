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
        throw "Patch 12h requires the working Patch-12g OpenMW 0.51 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit"
if ((Read-Lf $MarkerFile).Trim() -ne $ExpectedMarker) {
    throw 'Patch 12h refused a non-0.51-Final runtime payload.'
}

# Require the exact Patch-12g baseline. Patch 12h keeps the final crop bypass
# and changes only the earlier caster-bounds projection tightening stage.
$MwShadowText = Read-Lf $MwShadowTechnique
$ShadowCppText = Read-Lf $ShadowCpp
$ReceiverText = Read-Lf $ShadowReceiver
$CasterText = Read-Lf $ShadowCaster
$ShadowsBinHppText = Read-Lf $ShadowsBinHpp
$ShadowsBinCppText = Read-Lf $ShadowsBinCpp
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS')) {
    throw 'Patch 12h requires Patch 12e stable orthographic shadow basis.'
}
if (-not $ShadowCppText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP')) {
    throw 'Patch 12h requires Patch 12c orthographic shadows.'
}
if (-not $CasterText.Contains('OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING')) {
    throw 'Patch 12h requires Patch 12d native GLES2 shadow clipping.'
}
if (-not $ReceiverText.Contains('OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE') -or
    -not $ReceiverText.Contains('OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS')) {
    throw 'Patch 12h requires the Patch-12/12b GLES2 receiver baseline.'
}
if (-not $ShadowsBinHppText.Contains('OPENMW_ANDROID_051_SHADOW_GL_DIAG') -or
    -not $ShadowsBinCppText.Contains('OPENMW_SHADOW_GL_DIAG Patch 12f active')) {
    throw 'Patch 12h expects the Patch 12f diagnostic probes to remain present.'
}
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP')) {
    throw 'Patch 12h requires the currently tested Patch 12g no-main-frustum-crop baseline.'
}

# ---------------------------------------------------------------------------
# Patch 12g: bypass ONLY cropShadowCameraToMainFrustum() for the Android
# orthographic directional-light, non-cascaded shadow path.
#
# The earlier ComputeLightSpaceBounds projection tightening is deliberately
# retained so this remains a one-variable A/B test.
# ---------------------------------------------------------------------------
$OldCropBlock = @'
            if (settings->getMultipleShadowMapHint() == ShadowSettings::CASCADED)
            {
                cropShadowCameraToMainFrustum(frustum, camera, cascaseNear, cascadeFar, extraPlanes);
                for (const auto& plane : extraPlanes)
                    local_polytope.getPlaneList().push_back(plane);
                local_polytope.setupMask();
            }
            else
                cropShadowCameraToMainFrustum(frustum, camera, reducedNear, reducedFar, extraPlanes);
'@.TrimEnd([char[]]"`r`n")

$NewCropBlock = @'
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

Replace-Exact $MwShadowTechnique 'Patch 12g Android orthographic no-main-frustum-crop A/B' $OldCropBlock $NewCropBlock


# ---------------------------------------------------------------------------
# Patch 12h: bypass only the ComputeLightSpaceBounds-derived projection
# tightening for Android orthographic directional shadows.
# ---------------------------------------------------------------------------
$OldCasterBoundsCondition = @'
        if (/*numShadowMapsPerLight>1 &&*/ (_shadowedScene->getCastsShadowTraversalMask() & _worldMask) == 0)
'@.TrimEnd([char[]]"`r`n")

$NewCasterBoundsCondition = @'
        bool tightenProjectionToCasterBounds
            = (_shadowedScene->getCastsShadowTraversalMask() & _worldMask) == 0;
#ifdef ANDROID
        if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
            && pl.directionalLight)
        {
            // OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING
            // Diagnostic A/B: do not rescale the orthographic shadow
            // projection to currently visible caster extents.
            tightenProjectionToCasterBounds = false;
        }
#endif
        if (tightenProjectionToCasterBounds)
'@.TrimEnd([char[]]"`r`n")

Replace-Exact $MwShadowTechnique 'Patch 12h Android orthographic no-caster-bounds-tightening A/B' $OldCasterBoundsCondition $NewCasterBoundsCondition

# Teach future clean native source extraction the same Patch-12h semantic edit.
$Patcher = Read-Lf $RuntimePatcher
$PatcherInsertAnchor = '# Final structural verification.'
$Patcher12hBlock = @'
# ---------------------------------------------------------------------------
# Patch 12h: disable caster-extents projection tightening for Android
# orthographic directional shadows. Patch 12g remains separate and active.
# ---------------------------------------------------------------------------
no_caster_bounds_tightening_marker = 'OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING'
text = mwshadowtechnique.read_text(encoding='utf-8')
if no_caster_bounds_tightening_marker not in text:
    text = replace_once(
        text,
        '''        if (/*numShadowMapsPerLight>1 &&*/ (_shadowedScene->getCastsShadowTraversalMask() & _worldMask) == 0)
''',
        '''        bool tightenProjectionToCasterBounds
            = (_shadowedScene->getCastsShadowTraversalMask() & _worldMask) == 0;
#ifdef ANDROID
        if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
            && pl.directionalLight)
        {
            // OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING
            // Diagnostic A/B: do not rescale the orthographic shadow
            // projection to currently visible caster extents.
            tightenProjectionToCasterBounds = false;
        }
#endif
        if (tightenProjectionToCasterBounds)
''',
        'mwshadowtechnique.cpp/Android orthographic no-caster-bounds-tightening',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android orthographic no-caster-bounds-tightening A/B.')
else:
    print('Android orthographic no-caster-bounds-tightening A/B is already applied.')

# Final structural verification.
'@.TrimEnd([char[]]"`r`n")

if (-not $Patcher.Contains('OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING')) {
    $Count = ([regex]::Matches($Patcher, [regex]::Escape($PatcherInsertAnchor))).Count
    if ($Count -ne 1) {
        throw "Patch 12h permanent patcher: expected one final-verification anchor, found $Count"
    }
    $Patcher = $Patcher.Replace($PatcherInsertAnchor, $Patcher12hBlock)
}

$ReadyPrint = "print('OpenMW 0.51 Android runtime baseline patch: READY')"
$PatcherVerify = @'
if no_caster_bounds_tightening_marker not in mwshadowtechnique.read_text(encoding='utf-8'):
    raise SystemExit('OpenMW 0.51 Android orthographic no-caster-bounds-tightening marker is missing')

print('OpenMW 0.51 Android runtime baseline patch: READY')
'@.TrimEnd([char[]]"`r`n")
if (-not $Patcher.Contains('orthographic no-caster-bounds-tightening marker is missing')) {
    $Count = ([regex]::Matches($Patcher, [regex]::Escape($ReadyPrint))).Count
    if ($Count -ne 1) {
        throw "Patch 12h permanent verification: expected one READY print, found $Count"
    }
    $Patcher = $Patcher.Replace($ReadyPrint, $PatcherVerify)
}
Write-Utf8Lf $RuntimePatcher $Patcher

# Identify the exact A/B APK in Logcat. Patch 12f probes intentionally remain.
$Main = Read-Lf $MainActivity
$Main = $Main.Replace(
    'Synced OpenMW 0.51 Patch 12g no-main-frustum-crop GLES2 shadows over Patch 12f; post processing remains disabled',
    'Synced OpenMW 0.51 Patch 12h no-caster-bounds-tightening GLES2 shadows over Patch 12g; post processing remains disabled'
)
$Main = $Main.Replace(
    'OpenMW 0.51 Patch 12g runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false',
    'OpenMW 0.51 Patch 12h runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false'
)
Write-Utf8Lf $MainActivity $Main

# Source-side verification before linking.
$MwShadowText = Read-Lf $MwShadowTechnique
$PatcherText = Read-Lf $RuntimePatcher
$MainText = Read-Lf $MainActivity
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP')) {
    throw 'Patch 12h source verification failed: Patch 12g no-main-frustum-crop marker missing.'
}
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS')) {
    throw 'Patch 12h source verification failed: Patch 12e stable basis was lost.'
}
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP') -or
    -not $PatcherText.Contains('OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING')) {
    throw 'Patch 12h permanent patcher verification failed.'
}
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING')) {
    throw 'Patch 12h source verification failed: no-caster-bounds-tightening marker missing.'
}
if (-not $MainText.Contains('Patch 12h no-caster-bounds-tightening GLES2 shadows over Patch 12g')) {
    throw 'Patch 12h Logcat marker update failed.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch12h-disable-caster-bounds-tightening.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch12h-disable-caster-bounds-tightening.sh"

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

# Re-run the permanent semantic baseline. Patch 12f probes are working-source
# diagnostics and are therefore checked separately after this call.
python3 "$PATCHER" "$SOURCE"

if ! grep -Fq 'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP' "$MWST"; then
    echo 'ERROR: Patch-12g no-main-frustum-crop marker is missing.' >&2
    exit 21
fi
if ! grep -Fq 'OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING' "$MWST"; then
    echo 'ERROR: Patch-12h no-caster-bounds-tightening marker is missing.' >&2
    exit 34
fi
if ! grep -Fq 'OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS' "$MWST"; then
    echo 'ERROR: Patch-12e stable shadow basis was lost.' >&2
    exit 22
fi
if ! grep -Fq 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP' "$SHADOW_CPP"; then
    echo 'ERROR: Patch-12c orthographic shadow map was lost.' >&2
    exit 23
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' "$SHADOW_CAST"; then
    echo 'ERROR: Patch-12d native shadow clipping was lost.' >&2
    exit 24
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_FRAG" || \
   ! grep -Fq 'OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS' "$SHADOW_FRAG"; then
    echo 'ERROR: Patch-12/12b receiver baseline was lost.' >&2
    exit 25
fi
if ! grep -Fq 'OPENMW_ANDROID_051_SHADOW_GL_DIAG' "$SHADOWS_BIN_HPP" || \
   ! grep -Fq 'OPENMW_SHADOW_GL_DIAG Patch 12f active' "$SHADOWS_BIN_CPP"; then
    echo 'ERROR: Patch-12f diagnostic probes were unexpectedly lost.' >&2
    exit 26
fi
if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
    echo 'ERROR: pinned NDK llvm-strip/llvm-readelf is missing.' >&2
    exit 27
fi

echo
echo 'OpenMW 0.51 Patch 12h source: READY'
echo '  Projection: ORTHOGRAPHIC, exactly 1 shadow map'
echo '  Stable basis: Patch 12e world-axis directional-light basis'
echo '  Main-frustum crop: DISABLED on Android orthographic directional shadow path'
echo '  ComputeLightSpaceBounds tightening: DISABLED on Android orthographic directional shadow path'
echo '  Patch 12f GL probes: still present for correlation'
echo '  Post Processing / OMWFX: still forced OFF'
echo
echo "Incrementally rebuilding OpenMW only (parallelism=$JOBS) ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
if [ "${#BUILT_LIBS[@]}" -eq 0 ]; then
    echo "ERROR: rebuilt libopenmw.so not found under $BUILD" >&2
    exit 28
fi
if [ "${#BUILT_LIBS[@]}" -gt 1 ]; then
    printf 'ERROR: multiple rebuilt libopenmw.so candidates found:\n' >&2
    printf '  %s\n' "${BUILT_LIBS[@]}" >&2
    exit 29
fi
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

if ! grep -aFq 'OpenMW 0.51.0' "$SYMBOLS" || ! grep -aFq 'OpenMW 0.51.0' "$JNI"; then
    echo 'ERROR: rebuilt library does not identify as OpenMW 0.51.0.' >&2
    exit 30
fi
if ! grep -aFq 'OPENMW_SHADOW_GL_DIAG Patch 12f active' "$SYMBOLS"; then
    echo 'ERROR: rebuilt library lost the Patch-12f diagnostic marker.' >&2
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
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch12h-libopenmw.sha256"

echo
echo 'OpenMW 0.51 Patch 12h no-caster-bounds-tightening native rebuild: SUCCESS'
printf 'Packaged/stripped lib: %s (%s bytes)\n' "$JNI" "$JNI_SIZE"
printf 'Symbol/unstripped lib: %s (%s bytes)\n' "$SYMBOLS" "$SYMBOL_SIZE"
printf 'Packaged SHA-256: %s\n' "$JNI_SHA"
printf 'Symbol SHA-256:   %s\n' "$SYMBOL_SHA"
echo 'Next: rebuild/reinstall the APK normally in Android Studio and reproduce the same Vivec shadow-triangle cases.'
'@

$ShellScript = $ShellScript.Replace('__PROJECT__', (Quote-Bash $WslProject))
$ShellScript = $ShellScript.Replace('__JOBS__', $Jobs.ToString())
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsHelper, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 12h - Disable Caster-Bounds Tightening A/B' -ForegroundColor Cyan
Write-Host 'Patch 12g crop bypass stays active; Patch 12h additionally bypasses caster-bounds projection tightening.' -ForegroundColor Yellow
Write-Host 'Patch 12f diagnostics remain enabled; all other shadow settings stay unchanged.' -ForegroundColor Yellow
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
$MwShadowText = Read-Lf $MwShadowTechnique
$MainText = Read-Lf $MainActivity
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP')) {
    throw 'Patch 12h final source verification failed: Patch 12g no-main-frustum-crop marker missing.'
}
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING')) {
    throw 'Patch 12h final source verification failed: no-caster-bounds-tightening marker missing.'
}
if (-not $MainText.Contains('Patch 12h no-caster-bounds-tightening GLES2 shadows over Patch 12g')) {
    throw 'Patch 12h final Logcat marker verification failed.'
}
if (-not (Test-Path $SymbolLib)) {
    throw 'Patch 12h symbol library is missing after rebuild.'
}
$JniSize = (Get-Item $JniLib).Length
$SymbolSize = (Get-Item $SymbolLib).Length
if ($JniSize -ge $SymbolSize) {
    throw "Patch 12h strip verification failed: packaged=$JniSize symbols=$SymbolSize"
}

Write-Host ''
Write-Host 'Patch 12h is ready for APK assembly.' -ForegroundColor Green
Write-Host "Packaged SHA-256: $((Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host 'Test the exact same Vivec positions/camera angles with Match Sunlight to sun ON and OFF.' -ForegroundColor Cyan
