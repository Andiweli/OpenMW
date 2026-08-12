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
$Patch29Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch29-libopenmw.sha256'
$Patch35Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch35-libopenmw.sha256'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$Godrays = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\godrays_android_051_depthfixed_vivid.omwfx'
$Lensflare = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\lensflare_android_051_rayocc.omwfx'
$Bloom = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\gateh_bloom051.omwfx'
$RainLens = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\rainlens_android_051_v12_dense.omwfx'
$WetWorld = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\wetworld_android_051_weather.omwfx'
$WaterFragAsset = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\water.frag'

foreach ($Required in @(
    $MarkerFile,
    $JniLib,
    $SourceRoot,
    $BuildRoot,
    $Patch29Sha,
    $RuntimePatcher,
    $MainActivity,
    $BuildGradle,
    $Godrays,
    $Lensflare,
    $Bloom,
    $RainLens,
    $WetWorld,
    $WaterFragAsset
)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 35 requires the completed Patch-34 project plus the extracted Patch-35 files. Missing: $Required"
    }
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 35 refused a non-0.51.0-Final runtime payload.'
}

$ActualNativeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
$Patch29ExpectedSha = ((Get-Content -LiteralPath $Patch29Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$KnownNativeBase = $ActualNativeSha -eq $Patch29ExpectedSha
if (-not $KnownNativeBase -and (Test-Path -LiteralPath $Patch35Sha)) {
    $Patch35ExpectedSha = ((Get-Content -LiteralPath $Patch35Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $KnownNativeBase = $ActualNativeSha -eq $Patch35ExpectedSha
}
if (-not $KnownNativeBase) {
    throw "Patch 35 requires the exact Patch-29 base or an existing Patch-35 build. actual=$ActualNativeSha"
}

$PatcherText = Read-Lf $RuntimePatcher
foreach ($Need in @(
    'OPENMW_ANDROID_051_CPU_SUN_OCCLUSION',
    'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH',
    'OPENMW_ANDROID_051_WETWORLD_WATER_MASK',
    'setTextureDepth(getTexture(Tex_Depth, frameId))',
    'defineMap["wetWorldWaterMask"] = "1";',
    'OpenMW 0.51 Android OMWFX depth: Tex_Depth direct scene binding',
    'const RayResult hit = castRay(origin, dest, true, false);'
)) {
    if (-not $PatcherText.Contains($Need)) {
        throw "Patch 35 native patcher is incomplete: $Need"
    }
}

$MainText = Read-Lf $MainActivity
foreach ($Need in @(
    'OpenMW 0.51 Patch 35 Gate H5a runtime',
    '"wetworld_android_051_weather,godrays_android_051_depthfixed_vivid,lensflare_android_051_rayocc,gateh_bloom051,rainlens_android_051_v12_dense"',
    'val wetWorldShader = "wetworld_android_051_weather.omwfx"',
    'val godraysShader = "godrays_android_051_depthfixed_vivid.omwfx"',
    'val rainLensShader = "rainlens_android_051_v12_dense.omwfx"',
    'WEATHER-WETWORLD-PUDDLES-051+TEXDEPTH-VIVID-DYNAMIC-GODRAYS051+DIRECT-SUN-GLOW+LENSFLARE051+CPU-RAY-OCCLUSION+BLOOM+WEATHER-RAINLENS-V12-DENSE-051',
    '"transparent postpass" to if (omwfxGateH5aSelected) "true"',
    'launcher_shader_preset_applied_v35_openmw051_gate_h5a'
)) {
    if (-not $MainText.Contains($Need)) {
        throw "Patch 35 MainActivity is incomplete: $Need"
    }
}

$BlockedStart = $MainText.IndexOf('val gateH5aBlockedShaders = listOf(')
$BlockedEnd = $MainText.IndexOf("`n        )", $BlockedStart)
if ($BlockedStart -lt 0 -or $BlockedEnd -lt 0) {
    throw 'Patch 35 could not resolve the obsolete-shader block.'
}
$BlockedText = $MainText.Substring($BlockedStart, $BlockedEnd - $BlockedStart)
if ($BlockedText.Contains('godrays_android_051_depthfixed_vivid.omwfx') -or
    $BlockedText.Contains('lensflare_android_051_rayocc.omwfx') -or
    $BlockedText.Contains('gateh_bloom051.omwfx') -or
    $BlockedText.Contains('rainlens_android_051_v12_dense.omwfx') -or
    $BlockedText.Contains('wetworld_android_051_weather.omwfx')) {
    throw 'Patch 35 active OMWFX technique was accidentally added to the obsolete-shader block.'
}
foreach ($Obsolete in @(
    '"godrays_android.omwfx"',
    '"godrays_android_051.omwfx"',
    '"godrays_android_051_rayocc.omwfx"',
    '"godrays_android_051_dynamic.omwfx"',
    '"godrays_android_051_depthfixed.omwfx"',
    '"rainlens_android_051_weather.omwfx"',
    '"rainlens_android_051_teardrops.omwfx"',
    '"rainlens_android_051_v12.omwfx"'
)) {
    if (-not $BlockedText.Contains($Obsolete)) {
        throw "Patch 35 obsolete-shader block is missing: $Obsolete"
    }
}

$GradleText = Read-Lf $BuildGradle
foreach ($Need in @(
    'OpenMW 0.51 Patch 35',
    "file('src/main/assets/android_omwfx/godrays_android_051_depthfixed_vivid.omwfx')",
    "file('src/main/assets/android_omwfx/rainlens_android_051_v12_dense.omwfx')",
    "file('src/main/assets/android_omwfx/wetworld_android_051_weather.omwfx')",
    "file('src/main/assets/libopenmw/resources/shaders/compatibility/water.frag')",
    'def gateH5aGodrays =',
    'def gateH5aRainLens =',
    'def gateH5aWetWorld =',
    'openmw-051-patch35-libopenmw.sha256',
    'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH',
    'OPENMW_ANDROID_051_WETWORLD_WATER_MASK'
)) {
    if (-not $GradleText.Contains($Need)) {
        throw "Patch 35 Gradle gate is incomplete: $Need"
    }
}

$GodraysText = Read-Lf $Godrays
foreach ($Need in @(
    "uniform_float ray_strength {`n    default = 0.60;",
    "uniform_float ray_length {`n    default = 0.85;",
    "uniform_float sun_glow_strength {`n    default = 0.65;",
    "uniform_float direct_glare_strength {`n    default = 0.48;",
    'vec4 viewDir = omw.viewMatrix * vec4(discDir, 0.0);',
    'float depth = omw_GetDepth(clamp(uv, vec2(0.001), vec2(0.999)));',
    'return smoothstep(0.99970, 0.99999, depth);',
    'float shaftContrast = smoothstep(0.08, 0.92, shafts);',
    'shafts = mix(shafts, shaftContrast, 0.35);',
    'clamp(omw.sunOcclusion, 0.0, 1.0)',
    'light += warmColor * shaftIntensity * 0.78;',
    'for (int i = 0; i < 16; i += 1)',
    'version = "3.3-051-depthfixed-vivid";'
)) {
    if (-not $GodraysText.Contains($Need)) {
        throw "Patch 35 lost the Patch-30 vivid Godrays shader: $Need"
    }
}

foreach ($Forbidden in @(
    'omw_GetLinearDepth(',
    'Disable_SunGlare',
    'softRayPattern051(',
    'for (int i = 0; i < 8; i += 1)'
)) {
    if ($GodraysText.Contains($Forbidden)) {
        throw "Patch 35 Godrays shader contains a forbidden stale/static token: $Forbidden"
    }
}

$LensflareText = Read-Lf $Lensflare
foreach ($Need in @(
    'omw.sunVis * clamp(omw.sunOcclusion, 0.0, 1.0) * edgeFade051(sunUv)',
    'version = "2.1-051-rayocc";'
)) {
    if (-not $LensflareText.Contains($Need)) {
        throw "Patch 35 lost the device-proven Patch-26 Lensflare: $Need"
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
        throw "Patch 35 lost the calibrated Patch-20 Bloom: $Need"
    }
}

$RainLensText = Read-Lf $RainLens
foreach ($Need in @(
    "uniform_float rainlens_strength_v34 {`n    default = 0.72;",
    "uniform_float rainlens_refraction_v34 {`n    default = 0.92;",
    "uniform_float rainlens_density_v34 {`n    default = 0.90;",
    'float hash21051(vec2 p)',
    'vec4 movingDrop051(',
    'p.y += timeValue * speed;',
    'float timeValue = omw.simulationTime;',
    'if (weatherId == 4)',
    'if (weatherId == 5)',
    'float currentRain = rainForWeather051(omw.weatherID);',
    'float nextRain = rainForWeather051(omw.nextWeatherID);',
    'clamp(omw.weatherTransition, 0.0, 1.0)',
    'vec4 drop = movingDrop051(',
    'omw_TexCoord, 5.6, 0.215, 19.7, timeValue, wind, density',
    'float threshold = mix(0.94, 0.72, clamp(density, 0.0, 1.0));',
    'float refractionMix = clamp(mask * 0.82, 0.0, 0.82);',
    'result += vec3(0.028) * drop.w * rain;',
    'flags = Disable_Interiors, Disable_Underwater;',
    'version = "4.3-051-rainlens-v12-dense";'
)) {
    if (-not $RainLensText.Contains($Need)) {
        throw "Patch 35 RainLens shader is incomplete: $Need"
    }
}
foreach ($Forbidden in @(
    'omw_GetDepth(',
    'omw_GetLinearDepth(',
    'Disable_SunGlare',
    'sampler_2d',
    'omw.simulationTime * 0.001',
    'rainDropLayer051(',
    'rainHash3051(',
    'teardropLayer051('
)) {
    if ($RainLensText.Contains($Forbidden)) {
        throw "Patch 35 RainLens contains an unwanted dependency: $Forbidden"
    }
}

$WetWorldText = Read-Lf $WetWorld
foreach ($Need in @(
    "uniform_float wet_strength_v35 {`n    default = 0.92;",
    "uniform_float wet_darkening_v35 {`n    default = 0.30;",
    "uniform_float wet_sheen_v35 {`n    default = 0.34;",
    "uniform_float puddle_strength_v35 {`n    default = 0.62;",
    'float rainFactor051()',
    'float valueNoise051(vec2 p)',
    'vec3 reconstructedWorldNormal051(vec2 uv)',
    'float upFacing = smoothstep(0.30, 0.76, abs(n.z));',
    'float puddleMask = smoothstep(0.56, 0.76, puddleField)',
    'if (base.a < 0.25)',
    'flags = Disable_Interiors, Disable_Underwater;',
    'version = "5.0-051-weather-puddles";'
)) {
    if (-not $WetWorldText.Contains($Need)) {
        throw "Patch 35 WetWorld shader is incomplete: $Need"
    }
}
foreach ($Forbidden in @('dFdx(', 'dFdy(', 'sin(', 'sampler_2d')) {
    if ($WetWorldText.Contains($Forbidden)) {
        throw "Patch 35 WetWorld contains an unwanted GLES2 dependency: $Forbidden"
    }
}

$WaterFragText = Read-Lf $WaterFragAsset
foreach ($Need in @(
    'OPENMW_ANDROID_051_WETWORLD_WATER_MASK',
    '#if @wetWorldWaterMask',
    'gl_FragData[0].a = 0.0;',
    'rainCombined(position.xy/1000.0, waterTimer)'
)) {
    if (-not $WaterFragText.Contains($Need)) {
        throw "Patch 35 water.frag is incomplete: $Need"
    }
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch35-wetworld-puddles.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch35-wetworld-puddles.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="${OPENMW_PATCH35_PROJECT:?OPENMW_PATCH35_PROJECT is required}"
JOBS="${OPENMW_PATCH35_JOBS:?OPENMW_PATCH35_JOBS is required}"
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
WATER_CPP="$SOURCE/apps/openmw/mwrender/water.cpp"
WATER_FRAG="$SOURCE/files/shaders/compatibility/water.frag"
WATER_ASSET="$PROJECT/app/src/main/assets/libopenmw/resources/shaders/compatibility/water.frag"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
[[ "$(cat "$MARKER")" == "$EXPECTED_MARKER" ]] || { echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2; exit 80; }
[[ -f "$BUILD/CMakeCache.txt" ]] || { echo "ERROR: existing OpenMW CMake build tree is incomplete: $BUILD" >&2; exit 81; }
[[ -x "$STRIP" && -x "$READELF" ]] || { echo 'ERROR: pinned NDK tools are missing.' >&2; exit 82; }

python3 "$PATCHER" "$SOURCE"

grep -Fq 'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH' "$PP_CPP" || exit 83
grep -Fq 'setTextureDepth(getTexture(Tex_Depth, frameId))' "$PP_CPP" || exit 84
grep -Fq 'OPENMW_ANDROID_051_CPU_SUN_OCCLUSION' "$RM_CPP" || exit 85
grep -Fq 'OPENMW_ANDROID_051_WETWORLD_WATER_MASK' "$WATER_CPP" || exit 86
grep -Fq '#include <osg/BlendFunc>' "$WATER_CPP" || exit 87
[[ $(grep -Fc 'osg::BlendFunc::ZERO, osg::BlendFunc::ZERO' "$WATER_CPP") -ge 2 ]] || exit 88
grep -Fq 'defineMap["wetWorldWaterMask"] = "1";' "$WATER_CPP" || exit 89
grep -Fq 'OPENMW_ANDROID_051_WETWORLD_WATER_MASK' "$WATER_FRAG" || exit 90
grep -Fq '#if @wetWorldWaterMask' "$WATER_FRAG" || exit 91
grep -Fq 'gl_FragData[0].a = 0.0;' "$WATER_FRAG" || exit 92
grep -Fq 'rainCombined(position.xy/1000.0, waterTimer)' "$WATER_FRAG" || exit 93

echo 'Patch 35 source validation: PASS'
echo "Incrementally rebuilding OpenMW only (parallelism=$JOBS) ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
[[ ${#BUILT_LIBS[@]} -eq 1 ]] || { echo "ERROR: expected one libopenmw.so, found ${#BUILT_LIBS[@]}" >&2; exit 94; }
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")" "$(dirname "$WATER_ASSET")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
cp -f "$WATER_FRAG" "$WATER_ASSET"
"$STRIP" --strip-unneeded "$JNI"

for lib in "$SYMBOLS" "$JNI"; do
    grep -aFq 'OpenMW 0.51 Android Gate G PP init:' "$lib" || exit 95
    grep -aFq 'OpenMW 0.51 Android sun-occlusion ray:' "$lib" || exit 96
    grep -aFq 'OpenMW 0.51 Android OMWFX depth: Tex_Depth direct scene binding' "$lib" || exit 97
    grep -aFq 'wetWorldWaterMask' "$lib" || exit 98
done

grep -Fq 'OPENMW_ANDROID_051_WETWORLD_WATER_MASK' "$WATER_ASSET" || exit 99
grep -Fq 'rainCombined(position.xy/1000.0, waterTimer)' "$WATER_ASSET" || exit 100
[[ $(stat -c %s "$JNI") -lt $(stat -c %s "$SYMBOLS") ]] || { echo 'ERROR: JNI library was not stripped.' >&2; exit 101; }
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo 'ERROR: JNI library contains DWARF sections.' >&2
    exit 102
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch35-libopenmw.sha256"
echo "Patch 35 native rebuild SUCCESS - SHA256 $JNI_SHA"
'@

[IO.File]::WriteAllText(
    $WindowsHelper,
    ($ShellScript -replace "`r`n", "`n"),
    (New-Object Text.UTF8Encoding($false))
)

try {
    & wsl.exe env "OPENMW_PATCH35_PROJECT=$WslProject" "OPENMW_PATCH35_JOBS=$Jobs" bash $WslHelper
    if ($LASTEXITCODE -ne 0) {
        throw "WSL Patch 35 rebuild failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $WindowsHelper -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $Patch35Sha)) {
    throw 'Patch 35 native SHA file was not generated.'
}
$ExpectedPatch35Sha = ((Get-Content -LiteralPath $Patch35Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualPatch35Sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedPatch35Sha -ne $ActualPatch35Sha) {
    throw "Patch 35 SHA mismatch. expected=$ExpectedPatch35Sha actual=$ActualPatch35Sha"
}

foreach ($OldAsset in @(
    'godrays_android.omwfx',
    'godrays_android_051.omwfx',
    'godrays_android_051_rayocc.omwfx',
    'godrays_android_051_dynamic.omwfx',
    'godrays_android_051_depthfixed.omwfx',
    'rainlens_android.omwfx',
    'rainlens_android_051_weather.omwfx',
    'rainlens_android_051_teardrops.omwfx',
    'rainlens_android_051_v12.omwfx',
    'wetworld_android.omwfx'
)) {
    $OldPath = Join-Path $ProjectRoot ('app\src\main\assets\android_omwfx\' + $OldAsset)
    if (Test-Path -LiteralPath $OldPath) {
        Remove-Item -LiteralPath $OldPath -Force
    }
}

Write-Host 'OpenMW 0.51 Patch 35 Gate H5a validation: PASS'
Write-Host 'Native rebuild: YES - openmw target only'
Write-Host 'WetWorld: weather-driven wet upward surfaces, procedural puddles, exact native water exclusion'
Write-Host 'RainLens: confirmed Patch-34 v1.2 dense geometry retained'
Write-Host 'Runtime chain: wetworld_android_051_weather,godrays_android_051_depthfixed_vivid,lensflare_android_051_rayocc,gateh_bloom051,rainlens_android_051_v12_dense'
Write-Host 'Android OMWFX depth source remains: Tex_Depth direct scene binding'
Write-Host 'Expected ray logs remain: CLEAR / BLOCKED'
