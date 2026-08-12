$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$Patch26Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch26-libopenmw.sha256'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$Godrays = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\godrays_android_051_rayocc.omwfx'
$Lensflare = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\lensflare_android_051_rayocc.omwfx'
$Bloom = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\gateh_bloom051.omwfx'

foreach ($Required in @(
    $MarkerFile,
    $JniLib,
    $Patch26Sha,
    $RuntimePatcher,
    $MainActivity,
    $BuildGradle,
    $Godrays,
    $Lensflare,
    $Bloom
)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 27 requires the completed Patch-26 v2 project. Missing: $Required"
    }
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 27 refused a non-0.51.0-Final runtime payload.'
}

$ExpectedNativeSha = ((Get-Content -LiteralPath $Patch26Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualNativeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedNativeSha -ne $ActualNativeSha) {
    throw "Patch 27 requires the exact Patch-26 CPU-ray libopenmw.so. expected=$ExpectedNativeSha actual=$ActualNativeSha"
}

$PatcherText = Read-Lf $RuntimePatcher
foreach ($Need in @(
    'OPENMW_ANDROID_051_CPU_SUN_OCCLUSION',
    'const RayResult hit = castRay(origin, dest, true, false);',
    'sName = "sunOcclusion"',
    'OpenMW 0.51 Android sun-occlusion ray:'
)) {
    if (-not $PatcherText.Contains($Need)) {
        throw "Patch 27 CPU-ray base is incomplete: $Need"
    }
}

$MainText = Read-Lf $MainActivity
foreach ($Need in @(
    'OpenMW 0.51 Patch 27 Gate H3a runtime',
    '"godrays_android_051_rayocc,lensflare_android_051_rayocc,gateh_bloom051"',
    'val godraysShader = "godrays_android_051_rayocc.omwfx"',
    'val gateH3aBlockedShaders = listOf(',
    'GODRAYS051+DIRECT-SUN-GLOW+LENSFLARE051+CPU-RAY-OCCLUSION+BLOOM',
    'transparentPostpass=launcher'
)) {
    if (-not $MainText.Contains($Need)) {
        throw "Patch 27 MainActivity is incomplete: $Need"
    }
}

$BlockedStart = $MainText.IndexOf('val gateH3aBlockedShaders = listOf(')
$BlockedEnd = $MainText.IndexOf("`n        )", $BlockedStart)
if ($BlockedStart -lt 0 -or $BlockedEnd -lt 0) {
    throw 'Patch 27 could not resolve the obsolete-shader block.'
}
$BlockedText = $MainText.Substring($BlockedStart, $BlockedEnd - $BlockedStart)
if ($BlockedText.Contains('godrays_android_051_rayocc.omwfx') -or
    $BlockedText.Contains('lensflare_android_051_rayocc.omwfx') -or
    $BlockedText.Contains('gateh_bloom051.omwfx')) {
    throw 'Patch 27 active OMWFX technique was accidentally added to the obsolete-shader block.'
}
foreach ($Obsolete in @(
    '"godrays_android.omwfx"',
    '"godrays_android_051.omwfx"',
    '"lensflare_android_051_depthocc.omwfx"'
)) {
    if (-not $BlockedText.Contains($Obsolete)) {
        throw "Patch 27 obsolete-shader block is missing: $Obsolete"
    }
}

$GradleText = Read-Lf $BuildGradle
foreach ($Need in @(
    'OpenMW 0.51 Patch 27',
    "file('src/main/assets/android_omwfx/godrays_android_051_rayocc.omwfx')",
    'def gateH3aGodrays =',
    "new File(project.rootDir, 'buildscripts/openmw-051-patch26-libopenmw.sha256')"
)) {
    if (-not $GradleText.Contains($Need)) {
        throw "Patch 27 Gradle gate is incomplete: $Need"
    }
}

$GodraysText = Read-Lf $Godrays
foreach ($Need in @(
    "uniform_float ray_strength {`n    default = 0.22;",
    "uniform_float sun_glow_strength {`n    default = 0.65;",
    "uniform_float direct_glare_strength {`n    default = 0.48;",
    'vec4 viewDir = omw.viewMatrix * vec4(discDir, 0.0);',
    'clamp(omw.sunOcclusion, 0.0, 1.0)',
    'float directSun = 1.0 - smoothstep(0.035, 0.48, centerDistance);',
    'for (int i = 0; i < 8; i += 1)',
    'version = "3.0-051-rayocc";'
)) {
    if (-not $GodraysText.Contains($Need)) {
        throw "Patch 27 Godrays/Sun-Glow shader is incomplete: $Need"
    }
}
foreach ($Forbidden in @(
    'omw_GetLinearDepth(',
    'omw_GetDepth(',
    'Disable_SunGlare',
    'sunOcclusion(',
    'sunOcclusion051('
)) {
    if ($GodraysText.Contains($Forbidden)) {
        throw "Patch 27 Godrays/Sun-Glow shader contains forbidden depth/legacy occlusion token: $Forbidden"
    }
}

$LensflareText = Read-Lf $Lensflare
foreach ($Need in @(
    'omw.sunVis * clamp(omw.sunOcclusion, 0.0, 1.0) * edgeFade051(sunUv)',
    'version = "2.1-051-rayocc";'
)) {
    if (-not $LensflareText.Contains($Need)) {
        throw "Patch 27 lost the device-proven Patch-26 Lensflare base: $Need"
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
        throw "Patch 27 lost the calibrated Patch-20 Bloom base: $Need"
    }
}

foreach ($OldAsset in @(
    'godrays_android.omwfx',
    'godrays_android_051.omwfx'
)) {
    $OldPath = Join-Path $ProjectRoot ('app\src\main\assets\android_omwfx\' + $OldAsset)
    if (Test-Path -LiteralPath $OldPath) {
        Remove-Item -LiteralPath $OldPath -Force
    }
}

Write-Host 'OpenMW 0.51 Patch 27 Gate H3a validation: PASS'
Write-Host 'Native rebuild: NO'
Write-Host 'Runtime chain: godrays_android_051_rayocc,lensflare_android_051_rayocc,gateh_bloom051'
Write-Host 'Expected ray logs remain: CLEAR / BLOCKED'
