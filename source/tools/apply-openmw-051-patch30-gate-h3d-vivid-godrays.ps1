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

foreach ($Required in @(
    $MarkerFile,
    $JniLib,
    $Patch29Sha,
    $RuntimePatcher,
    $MainActivity,
    $BuildGradle,
    $Godrays,
    $Lensflare,
    $Bloom
)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 30 requires the completed Patch-29 project. Missing: $Required"
    }
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 30 refused a non-0.51.0-Final runtime payload.'
}

$ExpectedNativeSha = ((Get-Content -LiteralPath $Patch29Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualNativeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedNativeSha -ne $ActualNativeSha) {
    throw "Patch 30 requires the exact Patch-29 Tex_Depth/CPU-ray libopenmw.so. expected=$ExpectedNativeSha actual=$ActualNativeSha"
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
        throw "Patch 30 native base is incomplete: $Need"
    }
}

$MainText = Read-Lf $MainActivity
foreach ($Need in @(
    'OpenMW 0.51 Patch 30 Gate H3d runtime',
    '"godrays_android_051_depthfixed_vivid,lensflare_android_051_rayocc,gateh_bloom051"',
    'val godraysShader = "godrays_android_051_depthfixed_vivid.omwfx"',
    'TEXDEPTH-VIVID-DYNAMIC-GODRAYS051+DIRECT-SUN-GLOW+LENSFLARE051+CPU-RAY-OCCLUSION+BLOOM',
    '"transparent postpass" to if (omwfxGateH3dSelected) "true"',
    'launcher_shader_preset_applied_v30_openmw051_gate_h3d'
)) {
    if (-not $MainText.Contains($Need)) {
        throw "Patch 30 MainActivity is incomplete: $Need"
    }
}

$BlockedStart = $MainText.IndexOf('val gateH3dBlockedShaders = listOf(')
$BlockedEnd = $MainText.IndexOf("`n        )", $BlockedStart)
if ($BlockedStart -lt 0 -or $BlockedEnd -lt 0) {
    throw 'Patch 30 could not resolve the obsolete-shader block.'
}
$BlockedText = $MainText.Substring($BlockedStart, $BlockedEnd - $BlockedStart)
if ($BlockedText.Contains('godrays_android_051_depthfixed_vivid.omwfx') -or
    $BlockedText.Contains('lensflare_android_051_rayocc.omwfx') -or
    $BlockedText.Contains('gateh_bloom051.omwfx')) {
    throw 'Patch 30 active OMWFX technique was accidentally added to the obsolete-shader block.'
}
foreach ($Obsolete in @(
    '"godrays_android.omwfx"',
    '"godrays_android_051.omwfx"',
    '"godrays_android_051_rayocc.omwfx"',
    '"godrays_android_051_dynamic.omwfx"',
    '"godrays_android_051_depthfixed.omwfx"'
)) {
    if (-not $BlockedText.Contains($Obsolete)) {
        throw "Patch 30 obsolete-shader block is missing: $Obsolete"
    }
}

$GradleText = Read-Lf $BuildGradle
foreach ($Need in @(
    'OpenMW 0.51 Patch 30',
    "file('src/main/assets/android_omwfx/godrays_android_051_depthfixed_vivid.omwfx')",
    'def gateH3dGodrays =',
    'openmw-051-patch29-libopenmw.sha256',
    'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH'
)) {
    if (-not $GradleText.Contains($Need)) {
        throw "Patch 30 Gradle gate is incomplete: $Need"
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
        throw "Patch 30 vivid Godrays shader is incomplete: $Need"
    }
}

foreach ($Forbidden in @(
    'omw_GetLinearDepth(',
    'Disable_SunGlare',
    'softRayPattern051(',
    'for (int i = 0; i < 8; i += 1)'
)) {
    if ($GodraysText.Contains($Forbidden)) {
        throw "Patch 30 Godrays shader contains a forbidden stale/static token: $Forbidden"
    }
}

$LensflareText = Read-Lf $Lensflare
foreach ($Need in @(
    'omw.sunVis * clamp(omw.sunOcclusion, 0.0, 1.0) * edgeFade051(sunUv)',
    'version = "2.1-051-rayocc";'
)) {
    if (-not $LensflareText.Contains($Need)) {
        throw "Patch 30 lost the device-proven Patch-26 Lensflare: $Need"
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
        throw "Patch 30 lost the calibrated Patch-20 Bloom: $Need"
    }
}

foreach ($OldAsset in @(
    'godrays_android.omwfx',
    'godrays_android_051.omwfx',
    'godrays_android_051_rayocc.omwfx',
    'godrays_android_051_dynamic.omwfx',
    'godrays_android_051_depthfixed.omwfx'
)) {
    $OldPath = Join-Path $ProjectRoot ('app\src\main\assets\android_omwfx\' + $OldAsset)
    if (Test-Path -LiteralPath $OldPath) {
        Remove-Item -LiteralPath $OldPath -Force
    }
}

Write-Host 'OpenMW 0.51 Patch 30 Gate H3d validation: PASS'
Write-Host 'Native rebuild: NO'
Write-Host 'Godrays: 16 taps, strength 0.60, mask contrast 35 percent, shaft output 0.78'
Write-Host 'Runtime chain: godrays_android_051_depthfixed_vivid,lensflare_android_051_rayocc,gateh_bloom051'
Write-Host 'Android OMWFX depth source remains: Tex_Depth direct scene binding'
Write-Host 'Expected ray logs remain: CLEAR / BLOCKED'
