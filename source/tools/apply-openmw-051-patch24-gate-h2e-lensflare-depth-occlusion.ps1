param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Require-File([string]$RelativePath) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required Patch 24 file: $RelativePath"
    }
    return $path
}

function Require-Text([string]$Path, [string]$Needle, [string]$Description) {
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "Patch 24 validation failed: $Description"
    }
}

$main = Require-File "app/src/main/java/ui/activity/MainActivity.kt"
$gradle = Require-File "app/build.gradle"
$bloom = Require-File "app/src/main/assets/android_omwfx/gateh_bloom051.omwfx"
$lens = Require-File "app/src/main/assets/android_omwfx/lensflare_android_051_depthocc.omwfx"
$nativeLib = Require-File "app/src/main/jniLibs/arm64-v8a/libopenmw.so"
$nativeShaFile = Require-File "buildscripts/openmw-051-patch13-libopenmw.sha256"

Require-Text $main "OpenMW 0.51 Patch 24 Gate H2e runtime" "MainActivity runtime marker is missing."
Require-Text $main '"lensflare_android_051_depthocc,gateh_bloom051"' "MainActivity does not select the H2e chain."
Require-Text $main '"transparent postpass" to if (omwfxGateH2eSelected)' "OMWFX does not force the transparent depth postpass."
Require-Text $main "LENSFLARE051-SUNDEPTH-OCCLUDED+NATIVE-SUNGLARE+BLOOM" "MainActivity H2e stage marker is missing."
Require-Text $main 'val gateH2eBlockedShaders = listOf(' "H2e blocked-shader list is not declared."
Require-Text $gradle "Patch 24" "Gradle Patch-24 marker is missing."
Require-Text $gradle "lensflare_android_051_depthocc.omwfx" "Gradle does not validate the H2e lens flare asset."

$bloomText = Get-Content -LiteralPath $bloom -Raw
foreach ($needle in @(
    "uniform_float uThreshold {`n    default = 0.30;",
    "uniform_float uSkyFactor {`n    default = 0.60;",
    "uniform_float uRadius {`n    default = 0.55;",
    "uniform_float uStrength {`n    default = 0.35;"
)) {
    if (-not $bloomText.Contains($needle)) {
        throw "Patch 24 bloom baseline validation failed: missing $needle"
    }
}

$lensText = Get-Content -LiteralPath $lens -Raw
foreach ($needle in @(
    'OPENMW_ANDROID_051_LENSFLARE_SUN_DEPTH_OCCLUSION',
    'const float OPENMW051_SUN_DISTANCE = 1000.0;',
    'vec4 viewDir = omw.viewMatrix * vec4(discDir, 0.0);',
    'float expectedSunDepth = max(omw.near, -viewDir.z * OPENMW051_SUN_DISTANCE);',
    'float sunDepthVisibility051(vec2 uv, float expectedSunDepth)',
    'float blockDepth = expectedSunDepth * 0.965;',
    'float openDepth  = expectedSunDepth * 0.992;',
    'float sunOcclusion051(vec2 sunUv, float expectedSunDepth)',
    'float openFraction = visible / 13.0;',
    'return smoothstep(0.72, 0.94, openFraction);',
    'float visibility = omw.sunVis * edgeFade051(sunUv) * occlusion;',
    'passes = main;',
    'version = "2.2-051-depthocc";'
)) {
    if (-not $lensText.Contains($needle)) {
        throw "Patch 24 lens flare validation failed: missing $needle"
    }
}
if ($lensText.Contains('omw.far * 0.999') -or $lensText.Contains('Disable_SunGlare')) {
    throw "Patch 24 isolation failed: old far-depth occlusion or Disable_SunGlare remains in H2e shader."
}

$mainText = Get-Content -LiteralPath $main -Raw
$runtimeStartMarker = "private fun applyOpenMw051RuntimeGateSettings()"
$runtimeEndMarker = "// v14.2 OpenMW 0.50 launcher settings"
$runtimeStart = $mainText.IndexOf($runtimeStartMarker)
if ($runtimeStart -lt 0) { throw "Patch 24 validation failed: active runtime function missing." }
$runtimeEnd = $mainText.IndexOf($runtimeEndMarker, $runtimeStart)
if ($runtimeEnd -lt 0) { throw "Patch 24 validation failed: runtime function delimiter missing." }
$runtimeText = $mainText.Substring($runtimeStart, $runtimeEnd - $runtimeStart)
if (-not $runtimeText.Contains('"lensflare_android_051_depthocc,gateh_bloom051"')) {
    throw "Patch 24 validation failed: active runtime chain is not H2e."
}
if (-not $runtimeText.Contains('"transparent postpass" to if (omwfxGateH2eSelected)')) {
    throw "Patch 24 validation failed: active H2e runtime does not force transparent postpass."
}
foreach ($obsoleteChain in @(
    '"lensflare_android_051_occ,gateh_bloom051"',
    '"lensflare_android_051,gateh_bloom051"',
    '"lensflare_android,gateh_bloom051"'
)) {
    if ($runtimeText.Contains($obsoleteChain)) {
        throw "Patch 24 isolation failed: obsolete lensflare chain remains active: $obsoleteChain"
    }
}

$syncStart = $mainText.IndexOf('val gateH2eBlockedShaders = listOf(')
if ($syncStart -lt 0) { throw "Patch 24 validation failed: H2e cleanup list missing." }
$syncEnd = $mainText.IndexOf(')', $syncStart)
$blockedText = $mainText.Substring($syncStart, $syncEnd - $syncStart)
foreach ($requiredOld in @(
    '"lensflare_android.omwfx"',
    '"lensflare_android_051.omwfx"',
    '"lensflare_android_051_occ.omwfx"',
    '"godrays_android.omwfx"',
    '"rainlens_android.omwfx"',
    '"wetworld_android.omwfx"'
)) {
    if (-not $blockedText.Contains($requiredOld)) {
        throw "Patch 24 validation failed: obsolete/isolated shader is not removed: $requiredOld"
    }
}
if ($blockedText.Contains('"lensflare_android_051_depthocc.omwfx"')) {
    throw "Patch 24 isolation failed: active H2e lens flare is in its own delete list."
}

$expectedShaText = (Get-Content -LiteralPath $nativeShaFile -Raw).Trim()
$expectedSha = ($expectedShaText -split '\s+')[0].ToLowerInvariant()
$currentSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $nativeLib).Hash.ToLowerInvariant()
if ($expectedSha -ne $currentSha) {
    throw "Native libopenmw.so differs from the device-proven Patch 13 Gate G binary. Expected $expectedSha, actual $currentSha."
}

Write-Host "OpenMW 0.51 Patch 24 Gate H2e validation: PASS"
Write-Host "Native rebuild: NO"
Write-Host "OMWFX runtime chain: lensflare_android_051_depthocc,gateh_bloom051"
Write-Host "Lensflare occlusion: 13 samples relative to OpenMW's 1000-unit celestial sun depth"
Write-Host "OMWFX transparent postpass: FORCED ON (foliage/depth support)"
Write-Host "Builtin sunglare: RETAINED"
Write-Host "Godrays/RainLens/WetWorld: still isolated"
Write-Host "Expected: free sun restores Patch-22 flare; nearer walls/rocks/foliage suppress it"
