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
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'

foreach ($Required in @($MarkerFile, $JniLib, $SourceRoot, $BuildRoot, $MwShadowTechnique, $ShadowCpp, $ShadowReceiver, $ShadowCaster, $RuntimePatcher, $MainActivity)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 12e requires the working Patch-12d OpenMW 0.51 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit"
if ((Read-Lf $MarkerFile).Trim() -ne $ExpectedMarker) {
    throw 'Patch 12e refused a non-0.51-Final runtime payload.'
}

# Require the exact current Gate-F baseline. Patch 12e changes only the
# directional-light basis used to orient Android orthographic shadow maps.
$MwShadowText = Read-Lf $MwShadowTechnique
$ShadowCppText = Read-Lf $ShadowCpp
$ReceiverText = Read-Lf $ShadowReceiver
$CasterText = Read-Lf $ShadowCaster
$PatcherText = Read-Lf $RuntimePatcher
if (-not $ShadowCppText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP')) {
    throw 'Patch 12e requires Patch 12c orthographic shadows.'
}
if (-not $CasterText.Contains('OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING')) {
    throw 'Patch 12e requires Patch 12d native GLES2 shadow clipping.'
}
if (-not $ReceiverText.Contains('OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE') -or
    -not $ReceiverText.Contains('OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS')) {
    throw 'Patch 12e requires the Patch-12/12b manual receiver and bounds baseline.'
}

# ---------------------------------------------------------------------------
# Patch 12e: stable camera-independent basis for Android orthographic sun
# shadows. Upstream builds lightSide from lightDir x viewDir. That basis becomes
# ill-conditioned when the player looks close to the light direction and can
# flip as the camera crosses the 2-degree fallback threshold. The symptom is a
# view-dependent shadow projection that appears to move with the player/camera.
# Keep the actual light direction, crop, distance, fade and depth compare intact.
# ---------------------------------------------------------------------------
$OldBasisBlock = @'
    double dotProduct_v = positionedLight.lightDir * frustum.frustumCenterLine;
    double gamma_v = acos(dotProduct_v);
    if (gamma_v<osg::DegreesToRadians(settings->getPerspectiveShadowMapCutOffAngle()) || gamma_v>osg::DegreesToRadians(180.0-settings->getPerspectiveShadowMapCutOffAngle()))
    {
        OSG_INFO<<"View direction and Light direction below tolerance"<<std::endl;
        osg::Vec3d viewSide = osg::Matrixd::transform3x3(frustum.modelViewMatrix, osg::Vec3d(1.0,0.0,0.0));
        lightSide = positionedLight.lightDir ^ (viewSide ^ positionedLight.lightDir);
        lightSide.normalize();
    }
    else
    {
        lightSide = positionedLight.lightDir ^ frustum.frustumCenterLine;
        lightSide.normalize();
    }

    osg::Vec3d lightUp = lightSide ^ positionedLight.lightDir;
'@.TrimEnd([char[]]"`r`n")

$NewBasisBlock = @'
#ifdef ANDROID
    if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
        && positionedLight.directionalLight)
    {
        // OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS
        // Keep the sun direction unchanged, but orient the orthographic shadow
        // camera from a stable world axis instead of the main camera view.
        // This avoids the lightDir x viewDir singularity/fallback flip when the
        // player looks close to the sunlight direction.
        const osg::Vec3d stableAxis = fabs(positionedLight.lightDir.z()) < 0.95
            ? osg::Vec3d(0.0, 0.0, 1.0)
            : osg::Vec3d(0.0, 1.0, 0.0);
        lightSide = positionedLight.lightDir ^ stableAxis;
        if (lightSide.length2() < 1e-12)
            lightSide.set(1.0, 0.0, 0.0);
        else
            lightSide.normalize();
    }
    else
#endif
    {
        double dotProduct_v = positionedLight.lightDir * frustum.frustumCenterLine;
        double gamma_v = acos(dotProduct_v);
        if (gamma_v<osg::DegreesToRadians(settings->getPerspectiveShadowMapCutOffAngle()) || gamma_v>osg::DegreesToRadians(180.0-settings->getPerspectiveShadowMapCutOffAngle()))
        {
            OSG_INFO<<"View direction and Light direction below tolerance"<<std::endl;
            osg::Vec3d viewSide = osg::Matrixd::transform3x3(frustum.modelViewMatrix, osg::Vec3d(1.0,0.0,0.0));
            lightSide = positionedLight.lightDir ^ (viewSide ^ positionedLight.lightDir);
            lightSide.normalize();
        }
        else
        {
            lightSide = positionedLight.lightDir ^ frustum.frustumCenterLine;
            lightSide.normalize();
        }
    }

    osg::Vec3d lightUp = lightSide ^ positionedLight.lightDir;
    lightUp.normalize();
'@.TrimEnd([char[]]"`r`n")

Replace-Exact $MwShadowTechnique 'Patch 12e stable Android orthographic shadow basis' $OldBasisBlock $NewBasisBlock

# Teach clean native builds the same semantic patch.
$Patcher = Read-Lf $RuntimePatcher
$PatcherInsertAnchor = '# Final structural verification.'
$PatcherStableBlock = @'
# ---------------------------------------------------------------------------
# Patch 12e: stable camera-independent basis for Android orthographic sun maps.
# ---------------------------------------------------------------------------
stable_ortho_basis_marker = 'OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS'
text = mwshadowtechnique.read_text(encoding='utf-8')
if stable_ortho_basis_marker not in text:
    text = replace_once(
        text,
        '''    double dotProduct_v = positionedLight.lightDir * frustum.frustumCenterLine;
    double gamma_v = acos(dotProduct_v);
    if (gamma_v<osg::DegreesToRadians(settings->getPerspectiveShadowMapCutOffAngle()) || gamma_v>osg::DegreesToRadians(180.0-settings->getPerspectiveShadowMapCutOffAngle()))
    {
        OSG_INFO<<"View direction and Light direction below tolerance"<<std::endl;
        osg::Vec3d viewSide = osg::Matrixd::transform3x3(frustum.modelViewMatrix, osg::Vec3d(1.0,0.0,0.0));
        lightSide = positionedLight.lightDir ^ (viewSide ^ positionedLight.lightDir);
        lightSide.normalize();
    }
    else
    {
        lightSide = positionedLight.lightDir ^ frustum.frustumCenterLine;
        lightSide.normalize();
    }

    osg::Vec3d lightUp = lightSide ^ positionedLight.lightDir;
''',
        '''#ifdef ANDROID
    if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
        && positionedLight.directionalLight)
    {
        // OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS
        // Keep the sun direction unchanged, but orient the orthographic shadow
        // camera from a stable world axis instead of the main camera view.
        // This avoids the lightDir x viewDir singularity/fallback flip when the
        // player looks close to the sunlight direction.
        const osg::Vec3d stableAxis = fabs(positionedLight.lightDir.z()) < 0.95
            ? osg::Vec3d(0.0, 0.0, 1.0)
            : osg::Vec3d(0.0, 1.0, 0.0);
        lightSide = positionedLight.lightDir ^ stableAxis;
        if (lightSide.length2() < 1e-12)
            lightSide.set(1.0, 0.0, 0.0);
        else
            lightSide.normalize();
    }
    else
#endif
    {
        double dotProduct_v = positionedLight.lightDir * frustum.frustumCenterLine;
        double gamma_v = acos(dotProduct_v);
        if (gamma_v<osg::DegreesToRadians(settings->getPerspectiveShadowMapCutOffAngle()) || gamma_v>osg::DegreesToRadians(180.0-settings->getPerspectiveShadowMapCutOffAngle()))
        {
            OSG_INFO<<"View direction and Light direction below tolerance"<<std::endl;
            osg::Vec3d viewSide = osg::Matrixd::transform3x3(frustum.modelViewMatrix, osg::Vec3d(1.0,0.0,0.0));
            lightSide = positionedLight.lightDir ^ (viewSide ^ positionedLight.lightDir);
            lightSide.normalize();
        }
        else
        {
            lightSide = positionedLight.lightDir ^ frustum.frustumCenterLine;
            lightSide.normalize();
        }
    }

    osg::Vec3d lightUp = lightSide ^ positionedLight.lightDir;
    lightUp.normalize();
''',
        'mwshadowtechnique.cpp/stable Android orthographic shadow basis',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Applied stable Android orthographic shadow-camera basis.')
else:
    print('Stable Android orthographic shadow-camera basis is already applied.')

# Final structural verification.
'@.TrimEnd([char[]]"`r`n")
if (-not $Patcher.Contains('OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS')) {
    $Count = ([regex]::Matches($Patcher, [regex]::Escape($PatcherInsertAnchor))).Count
    if ($Count -ne 1) {
        throw "Patch 12e permanent patcher: expected one final-verification anchor, found $Count"
    }
    $Patcher = $Patcher.Replace($PatcherInsertAnchor, $PatcherStableBlock)
}

$PrintAnchor = "print('OpenMW 0.51 Android runtime baseline patch: READY')"
$PatcherVerify = @'
if stable_ortho_basis_marker not in mwshadowtechnique_text:
    raise SystemExit('OpenMW 0.51 Android stable orthographic shadow basis is missing')

print('OpenMW 0.51 Android runtime baseline patch: READY')
'@.TrimEnd([char[]]"`r`n")
if (-not $Patcher.Contains("stable orthographic shadow basis is missing")) {
    $Count = ([regex]::Matches($Patcher, [regex]::Escape($PrintAnchor))).Count
    if ($Count -ne 1) {
        throw "Patch 12e permanent verification: expected one READY print, found $Count"
    }
    $Patcher = $Patcher.Replace($PrintAnchor, $PatcherVerify)
}
Write-Utf8Lf $RuntimePatcher $Patcher

# Make Logcat identify the exact native gate under test.
$Main = Read-Lf $MainActivity
$Main = $Main.Replace(
    'Synced OpenMW 0.51 Patch 12d orthographic + native-clipped GLES2 shadows; post processing remains disabled',
    'Synced OpenMW 0.51 Patch 12e stable-basis orthographic GLES2 shadows; post processing remains disabled'
)
$Main = $Main.Replace(
    'OpenMW 0.51 Patch 12d runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false',
    'OpenMW 0.51 Patch 12e runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false'
)
Write-Utf8Lf $MainActivity $Main

# Source-side verification before native linking.
$MwShadowText = Read-Lf $MwShadowTechnique
$PatcherText = Read-Lf $RuntimePatcher
$MainText = Read-Lf $MainActivity
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS')) {
    throw 'Patch 12e source verification failed: stable basis marker missing.'
}
if (-not $MwShadowText.Contains('const osg::Vec3d stableAxis')) {
    throw 'Patch 12e source verification failed: stable world-axis basis incomplete.'
}
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING')) {
    throw 'Patch 12e source verification failed: Patch 12d native clipping was lost.'
}
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS')) {
    throw 'Patch 12e permanent patcher verification failed.'
}
if (-not $MainText.Contains('Patch 12e stable-basis orthographic GLES2 shadows')) {
    throw 'Patch 12e Logcat marker update failed.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch12e-stable-shadow-basis.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch12e-stable-shadow-basis.sh"

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

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
if [[ "$(cat "$MARKER")" != "$EXPECTED_MARKER" ]]; then
    echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2
    exit 20
fi
if [ ! -f "$SOURCE/CMakeLists.txt" ] || ! grep -Eq 'set\(OPENMW_VERSION_MINOR[[:space:]]+51\)' "$SOURCE/CMakeLists.txt"; then
    echo 'ERROR: extracted native source is not OpenMW 0.51.x.' >&2
    exit 21
fi

# Re-run the permanent semantic baseline to prove clean-build reproducibility.
python3 "$PATCHER" "$SOURCE"

if ! grep -Fq 'OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS' "$MWST"; then
    echo 'ERROR: Patch-12e stable orthographic basis is missing.' >&2
    exit 22
fi
if ! grep -Fq 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP' "$SHADOW_CPP"; then
    echo 'ERROR: Patch-12c orthographic projection was lost.' >&2
    exit 23
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' "$SHADOW_CAST" || \
   ! grep -Fq 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' "$MWST"; then
    echo 'ERROR: Patch-12d native caster clipping was lost.' >&2
    exit 24
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_FRAG" || \
   ! grep -Fq 'OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS' "$SHADOW_FRAG"; then
    echo 'ERROR: Patch-12/12b receiver compatibility was lost.' >&2
    exit 25
fi
if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
    echo 'ERROR: pinned NDK llvm-strip/llvm-readelf is missing.' >&2
    exit 26
fi

echo
echo 'OpenMW 0.51 Patch 12e source: READY'
echo '  Projection: ORTHOGRAPHIC, exactly 1 shadow map'
echo '  Caster clipping: native GLES2 near/far clipping'
echo '  Directional shadow-camera basis: stable world-axis basis (camera independent)'
echo '  Actual sunlight direction / quality / distance / fade: unchanged'
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
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch12e-libopenmw.sha256"

echo
echo 'OpenMW 0.51 Patch 12e stable-shadow-basis native rebuild: SUCCESS'
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
Write-Host 'OpenMW 0.51 Patch 12e - Stable Orthographic Shadow Basis' -ForegroundColor Cyan
Write-Host 'Targets the remaining Match Sunlight to sun = OFF view-dependent shadow triangles.' -ForegroundColor Cyan
Write-Host 'Light direction is NOT changed; only the shadow-camera side/up basis is stabilized.' -ForegroundColor Yellow
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
$PatcherText = Read-Lf $RuntimePatcher
$MainText = Read-Lf $MainActivity
if (-not $MwShadowText.Contains('OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS')) {
    throw 'Patch 12e final source verification failed.'
}
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS')) {
    throw 'Patch 12e final permanent-patcher verification failed.'
}
if (-not $MainText.Contains('Patch 12e stable-basis orthographic GLES2 shadows')) {
    throw 'Patch 12e final Logcat marker verification failed.'
}
if (-not (Test-Path $SymbolLib)) {
    throw 'Patch 12e symbol library is missing after rebuild.'
}
$JniSize = (Get-Item $JniLib).Length
$SymbolSize = (Get-Item $SymbolLib).Length
if ($JniSize -ge $SymbolSize) {
    throw "Patch 12e strip verification failed: packaged=$JniSize symbols=$SymbolSize"
}

Write-Host ''
Write-Host 'Patch 12e is ready for APK assembly.' -ForegroundColor Green
Write-Host "Packaged SHA-256: $((Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host 'Device test: first Match Sunlight to sun OFF at the known moving-shadow corner, then ON as regression check.' -ForegroundColor Cyan
