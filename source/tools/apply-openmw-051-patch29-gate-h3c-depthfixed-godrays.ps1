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

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported project path for WSL: $WindowsPath"
    }

    $DriveLetter = $Matches[1].ToLowerInvariant()
    $RelativePart = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($RelativePart)) {
        return "/mnt/$DriveLetter"
    }

    return "/mnt/$DriveLetter/" + (($RelativePart -replace '\\', '/').TrimStart('/'))
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$Godrays = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\godrays_android_051_depthfixed.omwfx'
$Lensflare = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\lensflare_android_051_rayocc.omwfx'
$Bloom = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\gateh_bloom051.omwfx'
$Patch26Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch26-libopenmw.sha256'
$Patch29Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch29-libopenmw.sha256'

foreach ($Required in @(
    $MarkerFile,
    $JniLib,
    $SourceRoot,
    $BuildRoot,
    $RuntimePatcher,
    $MainActivity,
    $BuildGradle,
    $Godrays,
    $Lensflare,
    $Bloom,
    $Patch26Sha
)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 29 requires the completed Patch-28/Patch-26-v2 project. Missing: $Required"
    }
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 29 refused a non-0.51.0-Final runtime payload.'
}

$CurrentSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
$Patch26ExpectedSha = ((Get-Content -LiteralPath $Patch26Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$KnownNativeBase = $CurrentSha -eq $Patch26ExpectedSha

if (-not $KnownNativeBase -and (Test-Path -LiteralPath $Patch29Sha)) {
    $Patch29ExpectedSha = ((Get-Content -LiteralPath $Patch29Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $KnownNativeBase = $CurrentSha -eq $Patch29ExpectedSha
}

if (-not $KnownNativeBase) {
    throw "Patch 29 requires the exact Patch-26 CPU-ray base or an existing Patch-29 build. actual=$CurrentSha"
}

$PatcherText = Read-Lf $RuntimePatcher
foreach ($Need in @(
    'OPENMW_ANDROID_051_CPU_SUN_OCCLUSION',
    'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH',
    'setTextureDepth(getTexture(Tex_Depth, frameId))',
    'OpenMW 0.51 Android OMWFX depth: Tex_Depth direct scene binding',
    'const RayResult hit = castRay(origin, dest, true, false);'
)) {
    if (-not $PatcherText.Contains($Need)) {
        throw "Patch 29 native patcher is incomplete: $Need"
    }
}

$MainText = Read-Lf $MainActivity
foreach ($Need in @(
    'OpenMW 0.51 Patch 29 Gate H3c runtime',
    '"godrays_android_051_depthfixed,lensflare_android_051_rayocc,gateh_bloom051"',
    'val godraysShader = "godrays_android_051_depthfixed.omwfx"',
    'TEXDEPTH-DYNAMIC-GODRAYS051+DIRECT-SUN-GLOW+LENSFLARE051+CPU-RAY-OCCLUSION+BLOOM',
    '"transparent postpass" to if (omwfxGateH3cSelected) "true"'
)) {
    if (-not $MainText.Contains($Need)) {
        throw "Patch 29 MainActivity is incomplete: $Need"
    }
}

$GradleText = Read-Lf $BuildGradle
foreach ($Need in @(
    'OpenMW 0.51 Patch 29',
    "file('src/main/assets/android_omwfx/godrays_android_051_depthfixed.omwfx')",
    'openmw-051-patch29-libopenmw.sha256',
    'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH'
)) {
    if (-not $GradleText.Contains($Need)) {
        throw "Patch 29 Gradle gate is incomplete: $Need"
    }
}

$GodraysText = Read-Lf $Godrays
foreach ($Need in @(
    "uniform_float ray_strength {`n    default = 0.48;",
    "uniform_float ray_length {`n    default = 0.85;",
    'float depth = omw_GetDepth(clamp(uv, vec2(0.001), vec2(0.999)));',
    'return smoothstep(0.99970, 0.99999, depth);',
    'clamp(omw.sunOcclusion, 0.0, 1.0)',
    'for (int i = 0; i < 16; i += 1)',
    'version = "3.2-051-depthfixed";'
)) {
    if (-not $GodraysText.Contains($Need)) {
        throw "Patch 29 Godrays shader is incomplete: $Need"
    }
}

foreach ($Forbidden in @(
    'omw_GetLinearDepth(',
    'Disable_SunGlare',
    'softRayPattern051('
)) {
    if ($GodraysText.Contains($Forbidden)) {
        throw "Patch 29 Godrays shader contains a forbidden stale token: $Forbidden"
    }
}

$LensflareText = Read-Lf $Lensflare
foreach ($Need in @(
    'omw.sunVis * clamp(omw.sunOcclusion, 0.0, 1.0) * edgeFade051(sunUv)',
    'version = "2.1-051-rayocc";'
)) {
    if (-not $LensflareText.Contains($Need)) {
        throw "Patch 29 lost the device-proven Patch-26 Lensflare: $Need"
    }
}

$BloomText = Read-Lf $Bloom
foreach ($Need in @(
    'passes = nomipmap, horizontal, vertical, final;',
    "uniform_float uThreshold {`n    default = 0.30;",
    "uniform_float uSkyFactor {`n    default = 0.60;",
    "uniform_float uStrength {`n    default = 0.35;"
)) {
    if (-not $BloomText.Contains($Need)) {
        throw "Patch 29 lost the calibrated Patch-20 Bloom: $Need"
    }
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch29-depthfixed-godrays.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch29-depthfixed-godrays.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="${OPENMW_PATCH29_PROJECT:?OPENMW_PATCH29_PROJECT is required}"
JOBS="${OPENMW_PATCH29_JOBS:?OPENMW_PATCH29_JOBS is required}"
SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
BUILD="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-runtime-baseline.py"
JNI="$PROJECT/app/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PROJECT/buildscripts/symbols/arm64-v8a/libopenmw.so"
MARKER="$PROJECT/app/src/main/assets/libopenmw/openmw/openmw-engine-version.txt"
STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

PP_CPP="$SOURCE/apps/openmw/mwrender/postprocessor.cpp"
RM_CPP="$SOURCE/apps/openmw/mwrender/renderingmanager.cpp"
RM_HPP="$SOURCE/apps/openmw/mwrender/renderingmanager.hpp"
FX_HPP="$SOURCE/components/fx/stateupdater.hpp"
MWST="$SOURCE/components/sceneutil/mwshadowtechnique.cpp"
SHADOW_CPP="$SOURCE/components/sceneutil/shadow.cpp"
SHADOW_FRAG="$SOURCE/files/shaders/compatibility/shadows_fragment.glsl"
SHADOW_CAST="$SOURCE/files/shaders/compatibility/shadowcasting.vert"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
[[ "$(cat "$MARKER")" == "$EXPECTED_MARKER" ]] || { echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2; exit 80; }
[[ -f "$BUILD/CMakeCache.txt" ]] || { echo "ERROR: existing OpenMW CMake build tree is incomplete: $BUILD" >&2; exit 81; }
[[ -x "$STRIP" && -x "$READELF" ]] || { echo 'ERROR: pinned NDK tools are missing.' >&2; exit 82; }

python3 "$PATCHER" "$SOURCE"

grep -Fq 'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH' "$PP_CPP" || { echo 'ERROR: scene-depth source marker missing.' >&2; exit 83; }
grep -Fq 'setTextureDepth(getTexture(Tex_Depth, frameId))' "$PP_CPP" || { echo 'ERROR: Tex_Depth canvas binding missing.' >&2; exit 84; }
grep -Fq 'setTextureDepth(getTexture(Tex_OpaqueDepth, frameId))' "$PP_CPP" || { echo 'ERROR: non-Android Tex_OpaqueDepth fallback missing.' >&2; exit 85; }
grep -Fq 'OpenMW 0.51 Android OMWFX depth: Tex_Depth direct scene binding' "$PP_CPP" || { echo 'ERROR: scene-depth runtime marker missing.' >&2; exit 86; }

for file in "$RM_CPP" "$RM_HPP" "$FX_HPP"; do
    grep -Fq 'OPENMW_ANDROID_051_CPU_SUN_OCCLUSION' "$file" || { echo "ERROR: CPU-ray marker missing: $file" >&2; exit 87; }
done
grep -Fq 'const RayResult hit = castRay(origin, dest, true, false);' "$RM_CPP" || exit 88
grep -Fq 'sName = "sunOcclusion"' "$FX_HPP" || exit 89

for marker in OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS; do
    grep -Fq "$marker" "$MWST" || { echo "ERROR: stable-shadow marker lost: $marker" >&2; exit 90; }
done
grep -Fq 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP' "$SHADOW_CPP" || exit 91
grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_FRAG" || exit 92
grep -Fq 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' "$SHADOW_CAST" || exit 93

echo 'Patch 29 source validation: PASS'
echo "Incrementally rebuilding OpenMW only (parallelism=$JOBS) ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
[[ ${#BUILT_LIBS[@]} -eq 1 ]] || { echo "ERROR: expected one libopenmw.so, found ${#BUILT_LIBS[@]}" >&2; exit 94; }
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

for lib in "$SYMBOLS" "$JNI"; do
    grep -aFq 'OpenMW 0.51 Android Gate G PP init:' "$lib" || exit 95
    grep -aFq 'OpenMW 0.51 Android sun-occlusion ray:' "$lib" || exit 96
    grep -aFq 'OpenMW 0.51 Android OMWFX depth: Tex_Depth direct scene binding' "$lib" || exit 97
done

[[ $(stat -c %s "$JNI") -lt $(stat -c %s "$SYMBOLS") ]] || { echo 'ERROR: JNI library was not stripped.' >&2; exit 98; }
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo 'ERROR: JNI library contains DWARF sections.' >&2
    exit 99
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch29-libopenmw.sha256"
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch13-libopenmw.sha256"
echo "Patch 29 native rebuild SUCCESS - SHA256 $JNI_SHA"
'@

[IO.File]::WriteAllText(
    $WindowsHelper,
    ($ShellScript -replace "`r`n", "`n"),
    (New-Object Text.UTF8Encoding($false))
)

try {
    & wsl.exe env "OPENMW_PATCH29_PROJECT=$WslProject" "OPENMW_PATCH29_JOBS=$Jobs" bash $WslHelper
    if ($LASTEXITCODE -ne 0) {
        throw "WSL Patch 29 rebuild failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $WindowsHelper -Force -ErrorAction SilentlyContinue
}

foreach ($OldAsset in @(
    'godrays_android.omwfx',
    'godrays_android_051.omwfx',
    'godrays_android_051_rayocc.omwfx',
    'godrays_android_051_dynamic.omwfx'
)) {
    $OldPath = Join-Path $ProjectRoot ('app\src\main\assets\android_omwfx\' + $OldAsset)
    if (Test-Path -LiteralPath $OldPath) {
        Remove-Item -LiteralPath $OldPath -Force
    }
}

if (-not (Test-Path -LiteralPath $Patch29Sha)) {
    throw 'Patch 29 native SHA file was not generated.'
}

$ExpectedSha = ((Get-Content -LiteralPath $Patch29Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedSha -ne $ActualSha) {
    throw "Patch 29 SHA mismatch. expected=$ExpectedSha actual=$ActualSha"
}

Write-Host 'OpenMW 0.51 Patch 29 Gate H3c validation: PASS'
Write-Host 'Native rebuild: YES - openmw target only'
Write-Host 'Runtime chain: godrays_android_051_depthfixed,lensflare_android_051_rayocc,gateh_bloom051'
Write-Host 'Android OMWFX depth source: Tex_Depth direct scene binding'
Write-Host 'Expected ray logs remain: CLEAR / BLOCKED'
