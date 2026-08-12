$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$Patch29Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch29-libopenmw.sha256'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$Godrays = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\godrays_android_051_depthfixed_vivid.omwfx'
$Lensflare = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\lensflare_android_051_rayocc.omwfx'
$Bloom = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\gateh_bloom051.omwfx'
$RainLens = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\rainlens_android_051_teardrops.omwfx'

foreach ($Required in @(
    $MarkerFile,
    $JniLib,
    $Patch29Sha,
    $RuntimePatcher,
    $MainActivity,
    $BuildGradle,
    $Godrays,
    $Lensflare,
    $Bloom,
    $RainLens
)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 32 requires the completed Patch-31 project plus the extracted Patch-32 files. Missing: $Required"
    }
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 32 refused a non-0.51.0-Final runtime payload.'
}

$ExpectedNativeSha = ((Get-Content -LiteralPath $Patch29Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualNativeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedNativeSha -ne $ActualNativeSha) {
    throw "Patch 32 requires the exact Patch-29 Tex_Depth/CPU-ray libopenmw.so retained by Patch 30. expected=$ExpectedNativeSha actual=$ActualNativeSha"
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
        throw "Patch 32 native base is incomplete: $Need"
    }
}

$MainText = Read-Lf $MainActivity
foreach ($Need in @(
    'OpenMW 0.51 Patch 32 Gate H4b runtime',
    '"godrays_android_051_depthfixed_vivid,lensflare_android_051_rayocc,gateh_bloom051,rainlens_android_051_teardrops"',
    'val godraysShader = "godrays_android_051_depthfixed_vivid.omwfx"',
    'val rainLensShader = "rainlens_android_051_teardrops.omwfx"',
    'TEXDEPTH-VIVID-DYNAMIC-GODRAYS051+DIRECT-SUN-GLOW+LENSFLARE051+CPU-RAY-OCCLUSION+BLOOM+WEATHER-TEARDROP-RAINLENS051',
    '"transparent postpass" to if (omwfxGateH4bSelected) "true"',
    'launcher_shader_preset_applied_v32_openmw051_gate_h4b'
)) {
    if (-not $MainText.Contains($Need)) {
        throw "Patch 32 MainActivity is incomplete: $Need"
    }
}

$BlockedStart = $MainText.IndexOf('val gateH4bBlockedShaders = listOf(')
$BlockedEnd = $MainText.IndexOf("`n        )", $BlockedStart)
if ($BlockedStart -lt 0 -or $BlockedEnd -lt 0) {
    throw 'Patch 32 could not resolve the obsolete-shader block.'
}
$BlockedText = $MainText.Substring($BlockedStart, $BlockedEnd - $BlockedStart)
if ($BlockedText.Contains('godrays_android_051_depthfixed_vivid.omwfx') -or
    $BlockedText.Contains('lensflare_android_051_rayocc.omwfx') -or
    $BlockedText.Contains('gateh_bloom051.omwfx') -or
    $BlockedText.Contains('rainlens_android_051_teardrops.omwfx')) {
    throw 'Patch 32 active OMWFX technique was accidentally added to the obsolete-shader block.'
}
foreach ($Obsolete in @(
    '"godrays_android.omwfx"',
    '"godrays_android_051.omwfx"',
    '"godrays_android_051_rayocc.omwfx"',
    '"godrays_android_051_dynamic.omwfx"',
    '"godrays_android_051_depthfixed.omwfx"',
    '"rainlens_android_051_weather.omwfx"'
)) {
    if (-not $BlockedText.Contains($Obsolete)) {
        throw "Patch 32 obsolete-shader block is missing: $Obsolete"
    }
}

$GradleText = Read-Lf $BuildGradle
foreach ($Need in @(
    'OpenMW 0.51 Patch 32',
    "file('src/main/assets/android_omwfx/godrays_android_051_depthfixed_vivid.omwfx')",
    "file('src/main/assets/android_omwfx/rainlens_android_051_teardrops.omwfx')",
    'def gateH4bGodrays =',
    'def gateH4bRainLens =',
    'openmw-051-patch29-libopenmw.sha256',
    'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH'
)) {
    if (-not $GradleText.Contains($Need)) {
        throw "Patch 32 Gradle gate is incomplete: $Need"
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
        throw "Patch 32 lost the Patch-30 vivid Godrays shader: $Need"
    }
}

foreach ($Forbidden in @(
    'omw_GetLinearDepth(',
    'Disable_SunGlare',
    'softRayPattern051(',
    'for (int i = 0; i < 8; i += 1)'
)) {
    if ($GodraysText.Contains($Forbidden)) {
        throw "Patch 32 Godrays shader contains a forbidden stale/static token: $Forbidden"
    }
}

$LensflareText = Read-Lf $Lensflare
foreach ($Need in @(
    'omw.sunVis * clamp(omw.sunOcclusion, 0.0, 1.0) * edgeFade051(sunUv)',
    'version = "2.1-051-rayocc";'
)) {
    if (-not $LensflareText.Contains($Need)) {
        throw "Patch 32 lost the device-proven Patch-26 Lensflare: $Need"
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
        throw "Patch 32 lost the calibrated Patch-20 Bloom: $Need"
    }
}

$RainLensText = Read-Lf $RainLens
foreach ($Need in @(
    "uniform_float rainlens_strength_v32 {`n    default = 0.58;",
    "uniform_float rainlens_refraction_v32 {`n    default = 0.72;",
    "uniform_float rainlens_density_v32 {`n    default = 0.32;",
    "uniform_float rainlens_fall_speed_v32 {`n    default = 1.00;",
    'vec3 rainHash3051(vec2 value)',
    'vec3 teardropLayer051(',
    'p.y += timeValue * speed * fallSpeed;',
    'float time = omw.simulationTime;',
    'if (weatherId == 4)',
    'if (weatherId == 5)',
    'float currentRain = rainWeather051(omw.weatherID);',
    'float nextRain = rainWeather051(omw.nextWeatherID);',
    'clamp(omw.weatherTransition, 0.0, 1.0)',
    'vec3 dropsA = teardropLayer051(',
    'vec3 dropsB = teardropLayer051(',
    'flags = Disable_Interiors, Disable_Underwater;',
    'version = "4.1-051-teardrops";'
)) {
    if (-not $RainLensText.Contains($Need)) {
        throw "Patch 32 RainLens shader is incomplete: $Need"
    }
}
foreach ($Forbidden in @(
    'omw_GetDepth(',
    'omw_GetLinearDepth(',
    'Disable_SunGlare',
    'sampler_2d',
    'omw.simulationTime * 0.001',
    'rainDropLayer051(',
    'sin('
)) {
    if ($RainLensText.Contains($Forbidden)) {
        throw "Patch 32 RainLens contains an unwanted dependency: $Forbidden"
    }
}

foreach ($OldAsset in @(
    'godrays_android.omwfx',
    'godrays_android_051.omwfx',
    'godrays_android_051_rayocc.omwfx',
    'godrays_android_051_dynamic.omwfx',
    'godrays_android_051_depthfixed.omwfx',
    'rainlens_android.omwfx',
    'rainlens_android_051_weather.omwfx'
)) {
    $OldPath = Join-Path $ProjectRoot ('app\src\main\assets\android_omwfx\' + $OldAsset)
    if (Test-Path -LiteralPath $OldPath) {
        Remove-Item -LiteralPath $OldPath -Force
    }
}

Write-Host 'OpenMW 0.51 Patch 32 Gate H4b validation: PASS'
Write-Host 'Native rebuild: NO'
Write-Host 'RainLens: weather IDs 4/5, smooth transitions, two sparse moving 0.50-style teardrop layers, one refraction tap'
Write-Host 'Runtime chain: godrays_android_051_depthfixed_vivid,lensflare_android_051_rayocc,gateh_bloom051,rainlens_android_051_teardrops'
Write-Host 'Android OMWFX depth source remains: Tex_Depth direct scene binding'
Write-Host 'Expected ray logs remain: CLEAR / BLOCKED'
